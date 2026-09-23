// ExportJob end to end on the generated burn-in media (Scripts/make_test_media.swift): a two-video-
// track sequence with a cross dissolve, a picture-in-picture still, an audio fade in, a gain change
// and a fade out is exported with every preset this machine has, and the file is decoded again
// with the phase-2 decoders: burn-in frame indices at 20 sampled frames (5 inside the dissolve,
// where the blend ratio must equal the frame-centre mix), the PiP layer, the beep's sample
// position, the audio RMS of the fades against a reference computed from the source media, exact
// durations, colour tags and the encoder's hardware flag against VideoToolbox's own answer (Matroska,
// which stores milliseconds: the beep within 1 ms). Plus cancel (prompt, the working file removed,
// nothing at the output), refusals before any file exists (missing or unreadable media, unwritable
// output, an output that is any of the project's media), an undecodable frame failing the export,
// memory over an 1800-frame 720p export with a stated per-frame growth bound, progress pacing, the
// writers' own guarantees (never replacing an existing file, a cancellable finish()), exports of a
// variable-frame-rate source, of an audio-only sequence (black pictures) and of a sequence without
// audio (a silent track). The encoders this machine is expected to have (Apple silicon with the
// repository's FFmpeg build: HEVC Main10, ProRes 422, SVT-AV1) fail the test when missing, unless
// FRAMEWRIGHT_ALLOW_MISSING_ENCODERS=1 turns that into a (visible) skip on other configurations.

#import <XCTest/XCTest.h>

#include "../../Engine/Export/ExportJob.h"
#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/FFmpeg/FFVideoEncoder.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "../../Engine/Model/Validation.h"
#include "../../Engine/Playback/PlaybackController.h"
#include "../../Engine/Render/Scheduler.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"
#include "../Media/VideoToolboxProbe.h"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <chrono>
#include <string>
#include <vector>

using namespace ve;
namespace ex = ve::exporting;

namespace {

/// Monotonic seconds (the tests' own clock for pacing and latency).
double nowSeconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

constexpr int kRate = 48000;

bool fileExists(const std::string &path) {
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0;
}

std::string parentOf(const std::string &path) {
    return path.substr(0, path.find_last_of('/'));
}

/// ThreadSanitizer's shadow memory grows with every address the process touches, so footprint
/// bounds mean nothing under it (the export runs, pacing and pressure are still checked).
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define VE_EXPORT_TESTS_UNDER_TSAN 1
#endif
#endif
#ifdef VE_EXPORT_TESTS_UNDER_TSAN
constexpr bool kFootprintIsMeaningful = false;
#else
constexpr bool kFootprintIsMeaningful = true;
#endif

/// Other configurations (an Intel Mac, an FFmpeg build without SVT-AV1) opt out of the encoders
/// this project's reference machine has.
bool missingEncodersAllowed() {
    const char *value = std::getenv("FRAMEWRIGHT_ALLOW_MISSING_ENCODERS");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

/// What one export reported.
struct Outcome {
    std::optional<media::Result<ex::ExportSummary>> result;
    std::vector<std::pair<double, ex::ExportProgress>> progress; // delivery time, report
    double completedAt = 0;
    double cancelledAt = 0;
    bool fileExistedAtCancel = false;
    bool outputExistedAtCancel = false;
    std::string workingPath;
    bool pressureApplied = false;
    std::vector<uint64_t> footprints; // physical footprint at progress deliveries
};

/// Project, router and cache for export tests (a 1920x1080 30 fps sequence with V1, V2, A1).
class ExportRig {
  public:
    explicit ExportRig(bool withFFmpeg = true) {
        router = media::BackendRouter::makeDefault();
        if (withFFmpeg) {
            (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        }
        cache = std::make_shared<media::FrameCache>();
        project.name = "Export";
        sequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 2, 1);
        v1 = sequence().videoTracks[0].id;
        v2 = sequence().videoTracks[1].id;
        a1 = sequence().audioTracks[0].id;
        queue = dispatch_queue_create("com.justjohn12345.framewright.tests.export-callbacks", DISPATCH_QUEUE_SERIAL);
    }

    Sequence &sequence() { return *project.findSequence(sequenceId); }

    AssetId importFile(const std::string &file) {
        std::string mediaError;
        const std::string path = test::testMediaPath(file, mediaError);
        if (path.empty()) {
            error = mediaError;
            return AssetId{};
        }
        return importPath(path);
    }

    AssetId importPath(const std::string &path) {
        auto routed = router->probe(path);
        if (!routed.ok()) {
            error = routed.error().description();
            return AssetId{};
        }
        const AssetId id = project.ids.make<AssetId>();
        auto asset = media::makeMediaAsset(*routed, id);
        if (!asset.ok()) {
            error = asset.error().description();
            return AssetId{};
        }
        project.assets.push_back(*asset);
        routing[id] = *routed;
        return id;
    }

    ClipId addClip(TrackId track, AssetId asset, int64_t start, int64_t frames, CMTime sourceIn) {
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = asset;
        clip.trackId = track;
        clip.timelineStart = CMTimeMake(start, 30);
        clip.timelineDuration = CMTimeMake(frames, 30);
        clip.sourceIn = sourceIn;
        clip.isStill = project.findAsset(asset)->isStill();
        Track &t = *sequence().findTrack(track);
        t.clips.push_back(clip);
        t.sortClips();
        return clip.id;
    }
    Clip &clip(ClipId id) { return *sequence().findClip(id); }
    void link(ClipId a, ClipId b) {
        clip(a).linkedClipId = b;
        clip(b).linkedClipId = a;
    }
    void addTransition(TrackId track, ClipId from, ClipId to, int64_t frames) {
        Transition t;
        t.id = project.ids.make<TransitionId>();
        t.trackId = track;
        t.fromClipId = from;
        t.toClipId = to;
        t.duration = CMTimeMake(frames, 30);
        sequence().transitions.push_back(t);
    }

    ex::ExportRequest request(media::VideoCodec codec, media::ContainerFormat container,
                              std::optional<media::AudioCodec> audio, const std::string &path, int bitDepth = 8,
                              int width = 1920, int height = 1080) const {
        ex::ExportRequest r;
        r.project = std::make_shared<const Project>(project);
        r.sequenceId = sequenceId;
        r.encode.container = container;
        media::VideoEncodeSettings v;
        v.codec = codec;
        v.width = width;
        v.height = height;
        v.quality = 0.8;
        r.encode.video = v;
        if (audio) {
            media::AudioEncodeSettings a;
            a.codec = *audio;
            a.bitRate = 256000;
            a.pcmBitDepth = 16;
            r.encode.audio = a;
        }
        r.videoBitDepth = bitDepth;
        r.outputPath = path;
        return r;
    }

    ex::ExportServices services() const {
        ex::ExportServices s;
        s.router = router;
        s.cache = cache;
        s.epoch = cache->epoch();
        s.routing = routing;
        return s;
    }

    /// Starts the export and waits for its completion. `onProgress` runs on the callback queue.
    Outcome run(const ex::ExportRequest &request, ex::ExportOptions options = {},
                const std::function<void(ex::ExportJob &, const ex::ExportProgress &, Outcome &)> &onProgress = {},
                std::optional<media::MediaError> *startError = nullptr) {
        auto outcome = std::make_shared<Outcome>();
        auto mutex = std::make_shared<std::mutex>();
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        auto jobRef = std::make_shared<std::weak_ptr<ex::ExportJob>>();
        auto started = ex::ExportJob::start(
            request, services(), options, queue,
            [outcome, mutex, jobRef, onProgress](const ex::ExportProgress &p) {
                std::lock_guard<std::mutex> lock(*mutex);
                outcome->progress.emplace_back(nowSeconds(), p);
                outcome->footprints.push_back(test::physicalFootprint());
                if (auto job = jobRef->lock(); job && onProgress) {
                    onProgress(*job, p, *outcome);
                }
            },
            [outcome, mutex, done](media::Result<ex::ExportSummary> result) {
                std::lock_guard<std::mutex> lock(*mutex);
                outcome->completedAt = nowSeconds();
                outcome->result = std::move(result);
                dispatch_semaphore_signal(done);
            });
        if (!started.ok()) {
            if (startError) {
                *startError = started.error();
            }
            return {};
        }
        {
            std::lock_guard<std::mutex> lock(*mutex); // the progress handler reads it on the callback queue
            *jobRef = started.value();
        }
        started.value().reset(); // the job keeps itself alive
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, int64_t(600) * NSEC_PER_SEC));
        std::lock_guard<std::mutex> lock(*mutex);
        return *outcome;
    }

    Project project;
    SequenceId sequenceId;
    TrackId v1, v2, a1;
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> cache;
    std::map<AssetId, media::RoutedMediaInfo> routing;
    dispatch_queue_t queue;
    std::string error;
};

// MARK: Reading decoded pictures

struct YCbCr {
    double y = 0, cb = 0, cr = 0; // 8-bit code units
    bool videoRange = true;
    bool rgb = false; // BGRA: y/cb/cr hold R/G/B
};

/// Mean of a region, as 8-bit codes (10-bit samples divided by 4).
YCbCr meanColor(CVPixelBufferRef buffer, size_t x0, size_t y0, size_t x1, size_t y1) {
    YCbCr out;
    const OSType f = CVPixelBufferGetPixelFormatType(buffer);
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (f == kCVPixelFormatType_32BGRA) {
        out.rgb = true;
        const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
        const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        double r = 0, g = 0, b = 0;
        size_t n = 0;
        for (size_t y = y0; y < y1; ++y) {
            for (size_t x = x0; x < x1; ++x) {
                const uint8_t *p = base + y * stride + x * 4;
                b += p[0];
                g += p[1];
                r += p[2];
                ++n;
            }
        }
        out.y = r / n;
        out.cb = g / n;
        out.cr = b / n;
    } else {
        const bool ten = media::isTenBitPixelFormat(f);
        out.videoRange = f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                         f == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange ||
                         f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                         f == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
                         f == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
        auto sample = [&](const uint8_t *row, size_t i) -> double {
            if (!ten) {
                return row[i];
            }
            uint16_t v;
            std::memcpy(&v, row + i * 2, 2);
            return (v >> 6) / 4.0;
        };
        const auto *luma = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
        const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        double sum = 0;
        size_t n = 0;
        for (size_t y = y0; y < y1; ++y) {
            for (size_t x = x0; x < x1; ++x) {
                sum += sample(luma + y * lumaStride, x);
                ++n;
            }
        }
        out.y = sum / n;
        const auto *chroma = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
        const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        const double sx = double(CVPixelBufferGetWidthOfPlane(buffer, 1)) / CVPixelBufferGetWidth(buffer);
        const double sy = double(CVPixelBufferGetHeightOfPlane(buffer, 1)) / CVPixelBufferGetHeight(buffer);
        double cb = 0, cr = 0;
        size_t m = 0;
        for (size_t y = size_t(y0 * sy); y < size_t(y1 * sy); ++y) {
            for (size_t x = size_t(x0 * sx); x < size_t(x1 * sx); ++x) {
                cb += sample(chroma + y * chromaStride, x * 2);
                cr += sample(chroma + y * chromaStride, x * 2 + 1);
                ++m;
            }
        }
        out.cb = cb / m;
        out.cr = cr / m;
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return out;
}

/// R, G, B (0...255) of a region (BT.709).
std::array<double, 3> meanRGB(CVPixelBufferRef buffer, size_t x0, size_t y0, size_t x1, size_t y1) {
    const YCbCr c = meanColor(buffer, x0, y0, x1, y1);
    if (c.rgb) {
        return {c.y, c.cb, c.cr};
    }
    const double y = c.videoRange ? (c.y - 16.0) / 219.0 : c.y / 255.0;
    const double cb = (c.cb - 128.0) / (c.videoRange ? 224.0 : 255.0);
    const double cr = (c.cr - 128.0) / (c.videoRange ? 224.0 : 255.0);
    return {255.0 * (y + 1.5748 * cr), 255.0 * (y - 0.18732 * cb - 0.46812 * cr), 255.0 * (y + 1.8556 * cb)};
}

/// Sequential reader of a file's first video track through the router.
class FrameReader {
  public:
    FrameReader(const media::BackendRouter &router, const std::string &path) {
        auto routed = router.probe(path);
        if (!routed.ok()) {
            error = routed.error().description();
            return;
        }
        info = *routed;
        auto decoder = router.makeVideoDecoder(*routed, -1, media::DecodeOptions{});
        if (!decoder.ok()) {
            error = decoder.error().description();
            return;
        }
        decoder_ = std::move(decoder->decoder);
    }
    std::optional<media::VideoFrame> frameAt(CMTime t) {
        if (!decoder_ || !decoder_->seek(t).ok()) {
            return std::nullopt;
        }
        auto next = decoder_->next();
        if (!next.ok() || !next.value()) {
            return std::nullopt;
        }
        return *next.value();
    }
    media::RoutedMediaInfo info;
    std::string error;

  private:
    std::unique_ptr<media::IVideoDecoder> decoder_;
};

/// All audio of a file (48 kHz stereo).
std::vector<float> decodeAudio(const media::BackendRouter &router, const std::string &path, int64_t from = 0,
                               int64_t frames = -1) {
    std::vector<float> out;
    auto routed = router.probe(path);
    if (!routed.ok()) {
        return out;
    }
    auto decoder = router.makeAudioDecoder(*routed, -1, media::AudioOptions{});
    if (!decoder.ok() || !decoder->decoder->seek(CMTimeMake(from, kRate)).ok()) {
        return out;
    }
    std::vector<float> chunk(4096 * 2);
    while (frames < 0 || int64_t(out.size() / 2) < frames) {
        auto n = decoder->decoder->read(chunk.data(), 4096);
        if (!n.ok() || n.value() <= 0) {
            break;
        }
        out.insert(out.end(), chunk.begin(), chunk.begin() + n.value() * 2);
    }
    if (frames >= 0 && int64_t(out.size() / 2) > frames) {
        out.resize(size_t(frames) * 2);
    }
    return out;
}

double rms(const std::vector<float> &interleaved, int64_t from, int64_t count) {
    double sum = 0;
    for (int64_t i = from; i < from + count; ++i) {
        const double v = interleaved[size_t(i) * 2];
        sum += v * v;
    }
    return std::sqrt(sum / double(count));
}

} // namespace

@interface ExportJobTests : XCTestCase
@end

@implementation ExportJobTests {
    std::string _dir;
}

- (void)setUp {
    _dir = ve::test::scratchDirectory();
}

- (std::string)output:(NSString *)name {
    return _dir + "/" + name.UTF8String;
}

/// True when the encoder is there. Otherwise a failure (this project's reference configuration has
/// every encoder the export offers), or a visible skip where FRAMEWRIGHT_ALLOW_MISSING_ENCODERS=1
/// says the configuration lacks it.
- (BOOL)requireEncoder:(BOOL)available what:(NSString *)what {
    if (available) {
        return YES;
    }
    if (missingEncodersAllowed()) {
        XCTSkip(@"no %@ on this configuration (FRAMEWRIGHT_ALLOW_MISSING_ENCODERS=1)", what);
    }
    XCTFail(@"no %@: expected on this configuration (set FRAMEWRIGHT_ALLOW_MISSING_ENCODERS=1 where it is not)", what);
    return NO;
}

// MARK: - The sync sequence

/// V1: clip A [0, 60) from source 0.5 s (burn-in 15 + f) and clip B [60, 150) from source 5 s
/// (burn-in 90 + f), a 10-frame dissolve on the cut (frames 55...64); V2: still.png at a quarter
/// size, bottom right, over [90, 120). A1: A's audio with a 0.5 s fade in (the media's beep at
/// source 2 s lands at 1.5 s = sample 72000), B's audio at -6 dB with a 1 s fade out.
- (void)buildSyncSequence:(ExportRig &)rig {
    const AssetId movie = rig.importFile("h264_1080p30.mp4");
    const AssetId still = rig.importFile("still.png");
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    const ClipId a = rig.addClip(rig.v1, movie, 0, 60, CMTimeMake(1, 2));
    const ClipId b = rig.addClip(rig.v1, movie, 60, 90, CMTimeMake(5, 1));
    rig.addTransition(rig.v1, a, b, 10);
    const ClipId pip = rig.addClip(rig.v2, still, 90, 30, kCMTimeZero);
    rig.clip(pip).video.scale = 0.25;
    rig.clip(pip).video.x = 600;
    rig.clip(pip).video.y = 300;
    const ClipId aa = rig.addClip(rig.a1, movie, 0, 60, CMTimeMake(1, 2));
    const ClipId ba = rig.addClip(rig.a1, movie, 60, 90, CMTimeMake(5, 1));
    rig.clip(aa).audio.fadeInDuration = CMTimeMake(15, 30);
    rig.clip(ba).audio.gainDb = -6.0;
    rig.clip(ba).audio.fadeOutDuration = CMTimeMake(30, 30);
    rig.link(a, aa);
    rig.link(b, ba);
    const auto problem = validateProject(rig.project);
    XCTAssertFalse(problem.has_value(), @"%s", problem ? problem->c_str() : "");
}

static int expectedBurnIn(int64_t f) {
    return f < 60 ? int(15 + f) : int(90 + f);
}

/// Exports the sync sequence and checks the file (see the file comment). `audioTolerance`: how
/// far (in 48 kHz samples) the audio length and the beep may be off: 1 for the sample-exact
/// containers (then the fade RMS is compared too), 48 (1 ms) for Matroska's millisecond timestamps.
- (void)exportSyncWithCodec:(media::VideoCodec)codec
                  container:(media::ContainerFormat)container
                      audio:(media::AudioCodec)audioCodec
                   bitDepth:(int)bitDepth
                       name:(NSString *)name
             audioTolerance:(int)audioTolerance {
    const BOOL fullAudio = audioTolerance <= 1;
    ExportRig rig;
    [self buildSyncSequence:rig];
    const std::string path = [self output:name];
    Outcome outcome = rig.run(rig.request(codec, container, audioCodec, path, bitDepth));
    XCTAssertTrue(outcome.result.has_value(), @"%@: no completion", name);
    if (!outcome.result || !outcome.result->ok()) {
        XCTFail(@"%@: %s", name, outcome.result ? outcome.result->error().description().c_str() : "timeout");
        return;
    }
    const ex::ExportSummary &summary = outcome.result->value();
    NSLog(@"EXPORT %@: %lld frames in %.2f s = %.1f fps, %llu bytes, %s (%s), backend %s", name,
          summary.frames, summary.wallSeconds, summary.averageFps, summary.bytes, summary.videoEncoder.c_str(),
          summary.hardwareEncoder ? "hardware" : "software", summary.writerBackend.c_str());
    XCTAssertEqual(summary.frames, 150);
    XCTAssertEqual(CMTimeCompare(summary.duration, CMTimeMake(5, 1)), 0);
    XCTAssertEqual(summary.audioFrames, 5 * kRate);
    struct stat st {};
    XCTAssertEqual(::stat(path.c_str(), &st), 0);
    XCTAssertEqual(summary.bytes, uint64_t(st.st_size));
    XCTAssertFalse(summary.videoEncoder.empty());
    if (codec == media::VideoCodec::AV1) {
        XCTAssertFalse(summary.hardwareEncoder, @"SVT-AV1 is software");
        XCTAssertEqual(summary.videoEncoder, std::string("libsvtav1"));
        XCTAssertEqual(summary.writerBackend, std::string("ffmpeg"));
    } else {
        // VideoToolbox's own answer for this codec and size.
        XCTAssertEqual(summary.hardwareEncoder,
                       test::videoToolboxEncodesInHardware(media::codecType(codec), 1920, 1080), @"%@", name);
        XCTAssertEqual(summary.writerBackend, std::string("apple"));
    }
    XCTAssertFalse(outcome.progress.empty(), @"progress was reported");

    // Container, durations, colour tags.
    FrameReader reader(*rig.router, path);
    XCTAssertTrue(reader.error.empty(), @"%s", reader.error.c_str());
    const media::TrackInfo *video = reader.info.info.firstTrack(media::TrackKind::Video);
    const media::TrackInfo *audio = reader.info.info.firstTrack(media::TrackKind::Audio);
    XCTAssertTrue(video != nullptr && audio != nullptr);
    if (!video || !audio) {
        return;
    }
    XCTAssertEqual(media::canonicalCodec(video->codec.fourCC), media::codecType(codec), @"%@ codec %s", name,
                   video->codec.fourCCString().c_str());
    XCTAssertEqual(video->width, 1920);
    XCTAssertEqual(video->height, 1080);
    XCTAssertEqual(CMTimeCompare(video->duration, CMTimeMake(5, 1)), 0, @"%@ video %.6f s", name,
                   CMTimeGetSeconds(video->duration));
    const double audioSeconds = CMTimeGetSeconds(audio->duration);
    XCTAssertEqualWithAccuracy(audioSeconds, 5.0, double(audioTolerance) / kRate + 1e-9, @"%@ audio", name);
    XCTAssertEqual(video->color.primaries, media::ColorPrimaries::BT709, @"%@", name);
    XCTAssertEqual(video->color.transfer, media::TransferFunction::BT709, @"%@", name);
    XCTAssertEqual(video->color.matrix, media::YCbCrMatrix::BT709, @"%@", name);
    if (bitDepth == 10) {
        XCTAssertEqual(video->bitDepth, 10, @"Main10");
    }

    // 15 frames outside the dissolve: the exact burn-in; the PiP still over [90, 120).
    const std::array<double, 3> pipColour = {40, 150, 160}; // kBurnInPalette[0x1234 % 8]
    for (int64_t f : {0, 5, 12, 20, 33, 47, 54, 65, 70, 89, 95, 110, 119, 130, 149}) {
        auto frame = reader.frameAt(CMTimeMake(f, 30));
        XCTAssertTrue(frame.has_value(), @"%@ frame %lld", name, f);
        if (!frame) {
            continue;
        }
        if (bitDepth == 10) {
            XCTAssertTrue(media::isTenBitPixelFormat(frame->image.pixelFormat()), @"decoded as 10-bit");
        }
        XCTAssertEqual(test::readBurnIn(frame->image.get()).value_or(-1), expectedBurnIn(f), @"%@ frame %lld", name, f);
        // The PiP patch shows the still's colour while it is on V2, else the clip's own
        // background colour (the palette entry of its burn-in index).
        const auto rgb = meanRGB(frame->image.get(), 1540, 820, 1580, 860);
        const bool pipShown = f >= 90 && f < 120;
        const test::RGB own = test::kBurnInPalette[expectedBurnIn(f) % 8];
        const std::array<double, 3> wanted =
            pipShown ? pipColour : std::array<double, 3>{double(own.r), double(own.g), double(own.b)};
        const double distance = std::max({std::fabs(rgb[0] - wanted[0]), std::fabs(rgb[1] - wanted[1]),
                                          std::fabs(rgb[2] - wanted[2])});
        XCTAssertLessThan(distance, 14.0, @"%@ frame %lld (%s): colour %.0f %.0f %.0f, want %.0f %.0f %.0f", name, f,
                          pipShown ? "PiP" : "no PiP", rgb[0], rgb[1], rgb[2], wanted[0], wanted[1], wanted[2]);
    }

    // 5 frames inside the dissolve: the background is the mix of A's and B's pictures with the
    // frame-centre ratio (k + 0.5) / 10, measured against the source frames themselves (the ratio
    // is the projection of the mixed colour onto the line from A's colour to B's: blending is
    // linear in R'G'B').
    FrameReader source(*rig.router, test::testMediaPath("h264_1080p30.mp4", rig.error));
    auto background = [](const media::VideoFrame &frame) {
        const double cell = double(frame.image.width()) / 18.0;
        return meanRGB(frame.image.get(), size_t(cell * 1.2), size_t(2.3 * cell), size_t(cell * 2.8),
                       size_t(2.7 * cell));
    };
    for (int64_t f : {57, 58, 59, 61, 62}) {
        auto mixed = reader.frameAt(CMTimeMake(f, 30));
        auto a = source.frameAt(CMTimeMake(15 + f, 30));
        auto b = source.frameAt(CMTimeMake(90 + f, 30));
        XCTAssertTrue(mixed && a && b);
        if (!mixed || !a || !b) {
            continue;
        }
        const auto m = background(*mixed);
        const auto ca = background(*a);
        const auto cb = background(*b);
        double dot = 0, norm = 0;
        for (int c = 0; c < 3; ++c) {
            dot += (m[c] - ca[c]) * (cb[c] - ca[c]);
            norm += (cb[c] - ca[c]) * (cb[c] - ca[c]);
        }
        const double ratio = dot / norm;
        const double expected = (double(f - 55) + 0.5) / 10.0;
        XCTAssertGreaterThan(norm, 900.0, @"frame %lld: A and B differ enough to measure", f);
        XCTAssertEqualWithAccuracy(ratio, expected, 0.03, @"%@ frame %lld: mix %.3f, want %.3f", name, f, ratio,
                                   expected);
    }

    // Audio: length, the beep's sample, and the fades against the source media.
    const std::vector<float> out = decodeAudio(*rig.router, path);
    const int64_t frames = int64_t(out.size() / 2);
    XCTAssertLessThanOrEqual(std::llabs(frames - 5 * kRate), audioTolerance, @"%@ audio frames %lld", name, frames);
    if (frames < 5 * kRate - audioTolerance) {
        return;
    }
    auto onset = test::findBeepOnset(out.data(), frames, 2, kRate);
    XCTAssertTrue(onset.has_value(), @"%@: beep", name);
    if (onset) {
        const double expected = (72000.0 + test::kBeepDetectorLatencyFrames48k) / kRate;
        const double errorSamples = std::fabs(*onset - expected) * kRate;
        NSLog(@"EXPORT %@: beep %.1f samples from where the timeline puts it", name, errorSamples);
        XCTAssertLessThanOrEqual(errorSamples, double(audioTolerance) + 1e-6, @"%@ beep at sample %.1f", name,
                                 *onset * kRate);
    }
    if (!fullAudio) {
        return;
    }
    const std::string sourcePath = test::testMediaPath("h264_1080p30.mp4", rig.error);
    // Fade in of A (timeline [0, 0.5 s) = source from 0.5 s), gain 1.
    const std::vector<float> srcA = decodeAudio(*rig.router, sourcePath, kRate / 2, kRate / 2);
    // B at -6 dB, fade out over [4 s, 5 s): timeline sample n is source sample n + 144000.
    const std::vector<float> srcB = decodeAudio(*rig.router, sourcePath, 5 * kRate, 3 * kRate);
    XCTAssertEqual(srcA.size(), size_t(kRate / 2) * 2);
    XCTAssertEqual(srcB.size(), size_t(3 * kRate) * 2);
    if (srcA.size() != size_t(kRate / 2) * 2 || srcB.size() != size_t(3 * kRate) * 2) {
        return;
    }
    const double gain = std::pow(10.0, -6.0 / 20.0);
    std::vector<float> reference(size_t(5 * kRate) * 2, 0.0f);
    for (int64_t n = 0; n < kRate / 2; ++n) {
        reference[size_t(n) * 2] = float(srcA[size_t(n) * 2] * (double(n) / (kRate / 2)));
    }
    for (int64_t n = 2 * kRate; n < 5 * kRate; ++n) {
        const double fade = n < 4 * kRate ? 1.0 : 1.0 - double(n - 4 * kRate) / kRate;
        reference[size_t(n) * 2] = float(srcB[size_t(n - 2 * kRate) * 2] * gain * fade);
    }
    double worst = 0;
    int windows = 0;
    auto compare = [&](int64_t from, int64_t to) {
        for (int64_t w = from; w + 2400 <= to; w += 2400) { // 50 ms windows
            const double diff = std::fabs(rms(out, w, 2400) - rms(reference, w, 2400));
            worst = std::max(worst, diff);
            ++windows;
            XCTAssertLessThan(diff, 1e-3, @"%@ RMS at %.3f s: %.5f vs %.5f", name, double(w) / kRate, rms(out, w, 2400),
                              rms(reference, w, 2400));
        }
    };
    compare(0, kRate / 2);            // fade in
    compare(5 * kRate / 2, 7 * kRate / 2); // steady at -6 dB
    compare(4 * kRate, 5 * kRate);    // fade out
    NSLog(@"EXPORT %@: audio RMS worst difference %.6f over %d windows", name, worst, windows);
}

- (void)testH264ExportRoundTrip {
    [self exportSyncWithCodec:media::VideoCodec::H264
                    container:media::ContainerFormat::MP4
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_h264.mp4"
             audioTolerance:1];
}

- (void)testHEVCExportRoundTrip {
    [self exportSyncWithCodec:media::VideoCodec::HEVC
                    container:media::ContainerFormat::MOV
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_hevc.mov"
             audioTolerance:1];
}

- (void)testHEVCMain10ExportRoundTrip {
    const auto availability = media::HardwareCaps::encoderAvailability(media::fourcc::HEVC, 1920, 1080, true);
    if (![self requireEncoder:availability.hardware || availability.software
                         what:[NSString stringWithFormat:@"a VideoToolbox HEVC Main10 encoder at 1920x1080 (%s)",
                                                         availability.reason.c_str()]]) {
        return;
    }
    [self exportSyncWithCodec:media::VideoCodec::HEVC
                    container:media::ContainerFormat::MP4
                        audio:media::AudioCodec::AAC
                     bitDepth:10
                         name:@"sync_hevc10.mp4"
             audioTolerance:1];
}

- (void)testProResExportRoundTrip {
    const auto availability = media::HardwareCaps::encoderAvailability(media::fourcc::ProRes422, 1920, 1080, false);
    if (![self requireEncoder:availability.hardware || availability.software
                         what:[NSString stringWithFormat:@"a VideoToolbox ProRes 422 encoder (%s)",
                                                         availability.reason.c_str()]]) {
        return;
    }
    [self exportSyncWithCodec:media::VideoCodec::ProRes422
                    container:media::ContainerFormat::MOV
                        audio:media::AudioCodec::LinearPCM
                     bitDepth:8
                         name:@"sync_prores.mov"
             audioTolerance:1];
}

- (void)testAV1ExportRoundTrip {
    if (![self requireEncoder:media::ffmpeg::FFVideoEncoder::isAvailable(media::VideoCodec::AV1)
                         what:@"FFmpeg's SVT-AV1 encoder (Scripts/build-ffmpeg.sh with ENABLE_SVTAV1=1)"]) {
        return;
    }
    [self exportSyncWithCodec:media::VideoCodec::AV1
                    container:media::ContainerFormat::MP4
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_av1.mp4"
             audioTolerance:1];
}

- (void)testAV1MatroskaExport {
    if (![self requireEncoder:media::ffmpeg::FFVideoEncoder::isAvailable(media::VideoCodec::AV1)
                         what:@"FFmpeg's SVT-AV1 encoder (Scripts/build-ffmpeg.sh with ENABLE_SVTAV1=1)"]) {
        return;
    }
    // Matroska stores millisecond timestamps: durations and the audio length are checked to 1 ms.
    [self exportSyncWithCodec:media::VideoCodec::AV1
                    container:media::ContainerFormat::MKV
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_av1.mkv"
             audioTolerance:48];
}

// MARK: - Cancel, refusals, failures

/// A 10 s single-clip A/V sequence (300 frames at 1080p).
- (void)buildLongSequence:(ExportRig &)rig {
    const AssetId movie = rig.importFile("h264_1080p30.mp4");
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    const ClipId v = rig.addClip(rig.v1, movie, 0, 300, kCMTimeZero);
    const ClipId a = rig.addClip(rig.a1, movie, 0, 300, kCMTimeZero);
    rig.link(v, a);
}

- (void)testCancelMidExportIsPromptAndLeavesNoFile {
    ExportRig rig;
    [self buildLongSequence:rig];
    const std::string path = [self output:@"cancelled.mp4"];
    Outcome outcome = rig.run(rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4,
                                          media::AudioCodec::AAC, path),
                              {}, [](ex::ExportJob &job, const ex::ExportProgress &p, Outcome &o) {
                                  if (p.framesDone >= 30 && o.cancelledAt == 0) {
                                      o.workingPath = job.workingPath();
                                      o.fileExistedAtCancel = fileExists(o.workingPath);
                                      o.outputExistedAtCancel = fileExists(job.request().outputPath);
                                      o.cancelledAt = nowSeconds();
                                      job.cancel();
                                  }
                              });
    XCTAssertTrue(outcome.result.has_value());
    XCTAssertGreaterThan(outcome.cancelledAt, 0.0, @"the export was cancelled mid-way");
    XCTAssertTrue(outcome.fileExistedAtCancel, @"writing had begun when it was cancelled: %s",
                  outcome.workingPath.c_str());
    XCTAssertFalse(outcome.outputExistedAtCancel, @"nothing is written at the output until the file is complete");
    XCTAssertNotEqual(parentOf(outcome.workingPath), parentOf(path), @"the working file is elsewhere");
    XCTAssertTrue(outcome.workingPath.size() > 13 &&
                      outcome.workingPath.compare(outcome.workingPath.size() - 13, 13, "cancelled.mp4") == 0,
                  @"and has the output's name: %s", outcome.workingPath.c_str());
    if (!outcome.result) {
        return;
    }
    XCTAssertFalse(outcome.result->ok());
    if (!outcome.result->ok()) {
        XCTAssertEqual(outcome.result->error().code, media::MediaErrorCode::Cancelled);
    }
    const double latency = outcome.completedAt - outcome.cancelledAt;
    NSLog(@"EXPORT cancel: completion %.1f ms after cancel()", latency * 1000);
    XCTAssertLessThan(latency, 0.5, @"cancel took %.3f s", latency);
    XCTAssertFalse(fileExists(path), @"no file at the output");
    XCTAssertFalse(fileExists(outcome.workingPath), @"the working file is deleted");
    XCTAssertFalse(fileExists(parentOf(outcome.workingPath)), @"and its directory");
    for (const auto &[t, p] : outcome.progress) {
        XCTAssertLessThanOrEqual(t, outcome.completedAt, @"no progress after the completion");
    }
}

- (void)testMissingAssetFailsBeforeAnyFileIsCreated {
    ExportRig rig;
    [self buildLongSequence:rig];
    rig.project.assets.front().url = _dir + "/moved-away.mp4";
    rig.project.assets.front().name = "moved-away.mp4";
    const std::string path = [self output:@"missing.mp4"];
    std::optional<media::MediaError> error;
    Outcome outcome = rig.run(rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4,
                                          media::AudioCodec::AAC, path),
                              {}, {}, &error);
    XCTAssertFalse(outcome.result.has_value(), @"no completion for a refused export");
    XCTAssertTrue(error.has_value());
    if (error) {
        XCTAssertEqual(error->code, media::MediaErrorCode::FileNotFound);
        XCTAssertNotEqual(error->message.find("“moved-away.mp4” is missing"), std::string::npos, @"%s",
                          error->message.c_str());
    }
    XCTAssertFalse(fileExists(path), @"no file was created");
}

- (void)testUnwritableOutputIsRefusedBeforeWriting {
    ExportRig rig;
    [self buildLongSequence:rig];
    const std::string path = _dir + "/no-such-folder/out.mp4";
    std::optional<media::MediaError> error;
    Outcome outcome = rig.run(rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4,
                                          media::AudioCodec::AAC, path),
                              {}, {}, &error);
    XCTAssertFalse(outcome.result.has_value());
    XCTAssertTrue(error.has_value());
    if (error) {
        XCTAssertEqual(error->code, media::MediaErrorCode::PermissionDenied, @"%s", error->message.c_str());
    }
    // A codec no writer takes is refused too (AV1 in MOV).
    auto av1 = rig.request(media::VideoCodec::AV1, media::ContainerFormat::MOV, std::nullopt, [self output:@"x.mov"]);
    media::Status refused = ex::ExportJob::validate(av1, rig.services());
    XCTAssertFalse(refused.ok());
    if (!refused.ok()) {
        XCTAssertEqual(refused.error().code, media::MediaErrorCode::UnsupportedCodec);
    }
    XCTAssertFalse(fileExists([self output:@"x.mov"]));
}

/// A picture that cannot be decoded fails the export: nothing is written in its place.
- (void)testUndecodableFrameFailsTheExport {
    auto behavior = std::make_shared<test::FakeBehavior>();
    behavior->frames = 90;
    behavior->failAtFrame = 40;
    behavior->probe = [](const std::string &path) -> media::Result<media::MediaInfo> {
        return test::makeFakeInfo(path, "mp4", media::fourcc::H264, false);
    };
    ExportRig rig(false);
    // The fake decodes; AVAssetWriter (Apple, registered second) writes.
    rig.router = std::make_shared<media::BackendRouter>();
    XCTAssertTrue(rig.router->registerBackend(std::make_shared<test::FakeBackend>(behavior)).ok());
    XCTAssertTrue(rig.router->registerBackend(media::apple::makeAppleBackend()).ok());
    rig.sequence().width = 288;
    rig.sequence().height = 162;
    const std::string media = _dir + "/fake-source.mp4";
    std::ofstream(media) << "not really a movie";
    const AssetId asset = rig.importPath(media);
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.addClip(rig.v1, asset, 0, 90, kCMTimeZero);
    const std::string path = [self output:@"undecodable.mp4"];
    Outcome outcome = rig.run(
        rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4, std::nullopt, path, 8, 288, 162));
    XCTAssertTrue(outcome.result.has_value());
    if (!outcome.result) {
        return;
    }
    XCTAssertFalse(outcome.result->ok(), @"the export must fail, not write a black frame");
    if (!outcome.result->ok()) {
        const std::string message = outcome.result->error().message;
        NSLog(@"EXPORT undecodable: %s", message.c_str());
        XCTAssertNotEqual(message.find("Frame 40 "), std::string::npos, @"%s", message.c_str());
        XCTAssertNotEqual(message.find("could not be decoded"), std::string::npos, @"%s", message.c_str());
    }
    XCTAssertFalse(fileExists(path));
}

// MARK: - Memory, speed and progress pacing

/// 1800 frames (60 s: the 10 s movie six times, with its audio) exported at 720p. The footprint,
/// sampled at every progress delivery (every 20 ms here: about 150 samples), must not trend upwards
/// once the pools are warm: the least-squares slope over frames 150...1800 stays under
/// kMaxGrowthPerFrame (a leak of one 720p frame in every 70 would exceed it), and the peak stays
/// within 48 MB of the first warm sample. Halfway, the system reports critical memory pressure: the
/// job drops its compositor scratch memory and the cache owner purges every unpinned frame (the pool
/// decodes again what the next frames need); the export must go on and complete. Progress is paced
/// at ExportOptions::progressInterval.
- (void)testMemoryIsFlatOver1800FramesAt720pSurvivesPressureAndProgressIsPaced {
    constexpr double kMaxGrowthPerFrame = 20.0 * 1024; // bytes
    constexpr int64_t kFrames = 1800;
    ExportRig rig;
    const AssetId movie = rig.importFile("h264_1080p30.mp4");
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    for (int64_t i = 0; i < kFrames / 300; ++i) {
        const ClipId v = rig.addClip(rig.v1, movie, i * 300, 300, kCMTimeZero);
        const ClipId a = rig.addClip(rig.a1, movie, i * 300, 300, kCMTimeZero);
        rig.link(v, a);
    }
    // MOV: AVAssetWriter writes QuickTime media data into the (working) file as it goes.
    const std::string path = [self output:@"long.mov"];
    auto cache = rig.cache;
    ex::ExportOptions options;
    options.progressInterval = 0.02;
    Outcome outcome = rig.run(
        rig.request(media::VideoCodec::H264, media::ContainerFormat::MOV, media::AudioCodec::AAC, path, 8, 1280, 720),
        options, [cache](ex::ExportJob &job, const ex::ExportProgress &p, Outcome &o) {
            if (p.framesDone >= kFrames / 2 && !o.pressureApplied) {
                o.pressureApplied = true;
                job.handleMemoryPressure(true);
                cache->handleMemoryPressure(media::MemoryPressure::Critical);
            }
        });
    XCTAssertTrue(outcome.pressureApplied, @"memory pressure was applied mid-export");
    XCTAssertTrue(outcome.result && outcome.result->ok(), @"%s",
                  outcome.result && !outcome.result->ok() ? outcome.result->error().description().c_str() : "");
    if (!outcome.result || !outcome.result->ok()) {
        return;
    }
    const ex::ExportSummary &summary = outcome.result->value();
    NSLog(@"EXPORT %lld frames H.264 720p: %.1f fps (%.2f s), %s", kFrames, summary.averageFps, summary.wallSeconds,
          summary.videoEncoder.c_str());
    XCTAssertEqual(summary.frames, kFrames);

    // Footprint against frames done, after the first 150 frames (pools warm).
    std::vector<std::pair<double, double>> samples; // (frames done, bytes)
    for (size_t i = 0; i < outcome.progress.size(); ++i) {
        if (outcome.progress[i].second.framesDone >= 150) {
            samples.emplace_back(double(outcome.progress[i].second.framesDone), double(outcome.footprints[i]));
        }
    }
    XCTAssertGreaterThanOrEqual(samples.size(), size_t(40), @"enough samples to see a trend");
    if (samples.size() >= 2) {
        double mx = 0, my = 0;
        for (const auto &[x, y] : samples) {
            mx += x;
            my += y;
        }
        mx /= double(samples.size());
        my /= double(samples.size());
        double sxy = 0, sxx = 0, peak = 0;
        for (const auto &[x, y] : samples) {
            sxy += (x - mx) * (y - my);
            sxx += (x - mx) * (x - mx);
            peak = std::max(peak, y);
        }
        const double slope = sxx > 0 ? sxy / sxx : 0;
        const double growthMB = (peak - samples.front().second) / (1024.0 * 1024.0);
        NSLog(@"EXPORT memory: %zu samples, first %.1f MB, peak %.1f MB (+%.1f MB), trend %+.1f KB per frame "
              @"(bound %.0f KB)",
              samples.size(), samples.front().second / 1048576.0, peak / 1048576.0, growthMB, slope / 1024.0,
              kMaxGrowthPerFrame / 1024.0);
        if (kFootprintIsMeaningful) {
            XCTAssertLessThan(slope, kMaxGrowthPerFrame, @"memory grows by %.1f KB per exported frame",
                              slope / 1024.0);
            XCTAssertLessThan(growthMB, 48.0, @"memory grew during the export");
        }
    }

    // Progress: at most one delivery per interval, increasing, with plausible numbers.
    for (size_t i = 1; i < outcome.progress.size(); ++i) {
        const double gap = outcome.progress[i].first - outcome.progress[i - 1].first;
        XCTAssertGreaterThanOrEqual(gap, options.progressInterval * 0.95, @"progress delivered %.3f s after the previous one",
                                    gap);
        XCTAssertGreaterThanOrEqual(outcome.progress[i].second.framesDone, outcome.progress[i - 1].second.framesDone);
    }
    if (outcome.progress.size() >= 2) {
        const ex::ExportProgress &late = outcome.progress.back().second;
        XCTAssertEqual(late.totalFrames, kFrames);
        XCTAssertGreaterThan(late.framesPerSecond, 0.0);
        XCTAssertGreaterThanOrEqual(late.etaSeconds, 0.0);
        XCTAssertGreaterThan(late.bytesWritten, 0u, @"the working file grows (MOV)");
    }
}

// MARK: - Refusals: media and output

/// Media that exists but cannot be read is a media problem (FileNotFound, which the facade reports
/// as missing media), not an unwritable output.
- (void)testUnreadableMediaIsRefusedAsMedia {
    ExportRig rig;
    std::string mediaError;
    const std::string source = test::testMediaPath("h264_1080p30.mp4", mediaError);
    XCTAssertTrue(mediaError.empty(), @"%s", mediaError.c_str());
    const std::string copy = _dir + "/locked.mp4";
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtPath:@(source.c_str()) toPath:@(copy.c_str()) error:nil]);
    const AssetId asset = rig.importPath(copy);
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.addClip(rig.v1, asset, 0, 30, kCMTimeZero);
    XCTAssertEqual(::chmod(copy.c_str(), 0), 0);
    const std::string path = [self output:@"unreadable.mp4"];
    media::Status refused = ex::ExportJob::validate(
        rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4, std::nullopt, path), rig.services());
    ::chmod(copy.c_str(), 0644);
    XCTAssertFalse(refused.ok());
    if (!refused.ok()) {
        XCTAssertEqual(refused.error().code, media::MediaErrorCode::FileNotFound, @"%s",
                       refused.error().description().c_str());
        XCTAssertNotEqual(refused.error().message.find("“locked.mp4” cannot be read"), std::string::npos, @"%s",
                          refused.error().message.c_str());
    }
    XCTAssertFalse(fileExists(path));
}

/// The output may not be any file of the project's media: one only in the bin, one on a muted
/// track, one on an audio track of a video-only export all count.
- (void)testOutputCannotBeAnyOfTheProjectsMedia {
    ExportRig rig;
    [self buildLongSequence:rig];
    std::string mediaError;
    const std::string source = test::testMediaPath("h264_1080p30.mp4", mediaError);
    const std::string binOnly = _dir + "/bin-only.mp4";
    const std::string muted = _dir + "/muted.mp4";
    for (const std::string &copy : {binOnly, muted}) {
        XCTAssertTrue([NSFileManager.defaultManager copyItemAtPath:@(source.c_str()) toPath:@(copy.c_str()) error:nil]);
    }
    const AssetId inBin = rig.importPath(binOnly);
    const AssetId onMuted = rig.importPath(muted);
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.addClip(rig.v2, onMuted, 0, 30, kCMTimeZero);
    rig.sequence().findTrack(rig.v2)->muted = true;
    (void)inBin;
    for (const std::string &target : {binOnly, muted, source}) {
        struct stat before {};
        XCTAssertEqual(::stat(target.c_str(), &before), 0);
        // A video-only export: the movie's audio clip on A1 is not exported, its file still counts.
        media::Status refused = ex::ExportJob::validate(
            rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4, std::nullopt, target), rig.services());
        XCTAssertFalse(refused.ok(), @"%s", target.c_str());
        if (!refused.ok()) {
            XCTAssertEqual(refused.error().code, media::MediaErrorCode::InvalidArgument);
            XCTAssertNotEqual(refused.error().message.find("would overwrite"), std::string::npos, @"%s",
                              refused.error().message.c_str());
        }
        struct stat after {};
        XCTAssertEqual(::stat(target.c_str(), &after), 0, @"%s is still there", target.c_str());
        XCTAssertEqual(after.st_size, before.st_size);
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec);
    }
    // Through another spelling of the same file.
    const std::string dotted = _dir + "/./bin-only.mp4";
    XCTAssertFalse(ex::ExportJob::validate(rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4,
                                                       std::nullopt, dotted),
                                           rig.services())
                       .ok());
}

// MARK: - The writers' guarantees

- (media::EncodeSettings)writerSettings:(media::VideoCodec)codec container:(media::ContainerFormat)container {
    media::EncodeSettings settings;
    settings.container = container;
    media::VideoEncodeSettings v;
    v.codec = codec;
    v.width = 320;
    v.height = 180;
    v.quality = 0.5;
    v.inputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    settings.video = v;
    return settings;
}

/// open() never deletes or truncates an existing file (ExportJob writes to a working file and
/// moves it into place): both writer backends refuse the path and leave the file as it was.
- (void)testWritersNeverReplaceAnExistingFile {
    auto router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    struct Case {
        media::VideoCodec codec;
        media::ContainerFormat container;
        const char *name;
    };
    for (const Case c : {Case{media::VideoCodec::H264, media::ContainerFormat::MP4, "existing.mp4"},
                         Case{media::VideoCodec::AV1, media::ContainerFormat::MKV, "existing.mkv"}}) {
        const std::string path = [self output:@(c.name)];
        std::ofstream(path, std::ios::binary) << "keep me";
        const media::EncodeSettings settings = [self writerSettings:c.codec container:c.container];
        auto made = router->makeWriter(settings);
        XCTAssertTrue(made.ok(), @"%s", c.name);
        if (!made.ok()) {
            continue;
        }
        media::Status opened = made->writer->open(path, settings);
        XCTAssertFalse(opened.ok(), @"%s (%s): open() must refuse an existing file", c.name, made->backend.c_str());
        if (!opened.ok()) {
            XCTAssertEqual(opened.error().code, media::MediaErrorCode::InvalidArgument, @"%s", c.name);
        }
        made->writer->cancel();
        std::ifstream in(path, std::ios::binary);
        const std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        XCTAssertEqual(content, std::string("keep me"), @"%s (%s)", c.name, made->backend.c_str());
    }
}

/// setFinishCancellation: a cancel while finish() completes the file (the MP4 index rewrite, the
/// encoders' flush) abandons it, deletes the partial file and reports Cancelled, on both backends.
- (void)testFinishIsCancellableOnBothWriters {
    auto router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    struct Case {
        media::VideoCodec codec;
        media::ContainerFormat container;
        const char *name;
    };
    for (const Case c : {Case{media::VideoCodec::H264, media::ContainerFormat::MP4, "finish.mp4"},
                         Case{media::VideoCodec::AV1, media::ContainerFormat::MKV, "finish.mkv"}}) {
        const std::string path = [self output:@(c.name)];
        const media::EncodeSettings settings = [self writerSettings:c.codec container:c.container];
        auto made = router->makeWriter(settings);
        XCTAssertTrue(made.ok(), @"%s", c.name);
        if (!made.ok()) {
            continue;
        }
        media::IMediaWriter &writer = *made->writer;
        XCTAssertTrue(writer.open(path, settings).ok(), @"%s", c.name);
        for (int i = 0; i < 30; ++i) {
            auto buffer = writer.makePixelBuffer();
            XCTAssertTrue(buffer.ok());
            if (!buffer.ok() || !writer.appendVideo(buffer.value(), CMTimeMake(i, 30)).ok()) {
                XCTFail(@"%s: append %d", c.name, i);
                break;
            }
        }
        std::atomic<int> checks{0};
        writer.setFinishCancellation([&checks] {
            ++checks;
            return true;
        });
        media::Status finished = writer.finish();
        XCTAssertFalse(finished.ok(), @"%s (%s)", c.name, made->backend.c_str());
        if (!finished.ok()) {
            XCTAssertEqual(finished.error().code, media::MediaErrorCode::Cancelled, @"%s: %s", c.name,
                           finished.error().description().c_str());
        }
        XCTAssertGreaterThan(checks.load(), 0, @"%s: finish() asked", c.name);
        XCTAssertFalse(fileExists(path), @"%s (%s): the partial file is deleted", c.name, made->backend.c_str());
    }
}

// MARK: - Sources and sequences of other shapes

/// A variable-frame-rate source (vfr_h264.mp4: frame durations cycle through kVfrPattern600, and
/// B-frames) exported at 30 fps: every sampled frame shows the source frame the program monitor
/// picks for it (the frame containing the layer's exact source time), read from the burn-in.
- (void)testVariableFrameRateSourceExportsTheMonitorsFrames {
    ExportRig rig;
    rig.sequence().width = 640;
    rig.sequence().height = 360;
    const AssetId vfr = rig.importFile("vfr_h264.mp4");
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    const MediaAsset &asset = *rig.project.findAsset(vfr);
    const int64_t frames = frameIndexAt(test::vfrFrameTime(test::kVfrFrames), CMTimeMake(1, 30), SnapMode::Floor);
    rig.addClip(rig.v1, vfr, 0, frames, kCMTimeZero);
    const auto problem = validateProject(rig.project);
    XCTAssertFalse(problem.has_value(), @"%s", problem ? problem->c_str() : "");
    const std::string path = [self output:@"vfr.mp4"];
    Outcome outcome = rig.run(
        rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4, std::nullopt, path, 8, 640, 360));
    XCTAssertTrue(outcome.result && outcome.result->ok(), @"%s",
                  outcome.result && !outcome.result->ok() ? outcome.result->error().description().c_str() : "");
    if (!outcome.result || !outcome.result->ok()) {
        return;
    }
    XCTAssertEqual(outcome.result->value().frames, frames);
    FrameReader reader(*rig.router, path);
    XCTAssertTrue(reader.error.empty(), @"%s", reader.error.c_str());
    int checked = 0;
    for (int64_t f = 0; f < frames; f += 7) {
        const RenderGraph graph = Scheduler::renderGraphAt(rig.sequence(), rig.project, CMTimeMake(f, 30));
        XCTAssertEqual(graph.layers.size(), size_t(1));
        if (graph.layers.size() != 1) {
            continue;
        }
        const CMTime source = playback::pictureTimeFor(graph.layers[0], asset);
        XCTAssertEqual(CMTimeCompare(source, CMTimeMake(f, 30)), 0, @"speed 1 from 0: the exact source time");
        const int expected = test::vfrFrameAt(source);
        auto frame = reader.frameAt(CMTimeMake(f, 30));
        XCTAssertTrue(frame.has_value(), @"frame %lld", f);
        if (frame) {
            XCTAssertEqual(test::readBurnIn(frame->image.get()).value_or(-1), expected,
                           @"sequence frame %lld (source %.4f s)", f, CMTimeGetSeconds(source));
            ++checked;
        }
    }
    NSLog(@"EXPORT VFR: %lld frames exported, %d checked against the monitor's choice", frames, checked);
    XCTAssertGreaterThan(checked, 10);
}

/// A sequence with only audio exports black pictures with the audio in place; a sequence without
/// audio clips gets a silent audio track of its full length when audio is exported.
- (void)testAudioOnlyAndSilentSequences {
    {
        ExportRig rig;
        rig.sequence().width = 640;
        rig.sequence().height = 360;
        const AssetId movie = rig.importFile("h264_1080p30.mp4");
        XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
        rig.addClip(rig.a1, movie, 0, 90, CMTimeMake(1, 1)); // the beep (source 2 s) at 1 s
        const std::string path = [self output:@"audio-only.mp4"];
        Outcome outcome = rig.run(
            rig.request(media::VideoCodec::H264, media::ContainerFormat::MP4, media::AudioCodec::AAC, path, 8, 640, 360));
        XCTAssertTrue(outcome.result && outcome.result->ok(), @"%s",
                      outcome.result && !outcome.result->ok() ? outcome.result->error().description().c_str() : "");
        if (outcome.result && outcome.result->ok()) {
            XCTAssertEqual(outcome.result->value().frames, 90);
            FrameReader reader(*rig.router, path);
            for (int64_t f : {0, 45, 89}) {
                auto frame = reader.frameAt(CMTimeMake(f, 30));
                XCTAssertTrue(frame.has_value(), @"frame %lld", f);
                if (frame) {
                    const auto rgb = meanRGB(frame->image.get(), 0, 0, 640, 360);
                    XCTAssertLessThan(std::max({rgb[0], rgb[1], rgb[2]}), 3.0, @"frame %lld is black: %.1f %.1f %.1f",
                                      f, rgb[0], rgb[1], rgb[2]);
                }
            }
            const std::vector<float> audio = decodeAudio(*rig.router, path);
            XCTAssertLessThanOrEqual(std::llabs(int64_t(audio.size() / 2) - 3 * kRate), 1);
            auto onset = test::findBeepOnset(audio.data(), int64_t(audio.size() / 2), 2, kRate);
            XCTAssertTrue(onset.has_value());
            if (onset) {
                XCTAssertLessThanOrEqual(
                    std::fabs(*onset * kRate - (48000.0 + test::kBeepDetectorLatencyFrames48k)), 1.0 + 1e-6,
                    @"beep at sample %.1f", *onset * kRate);
            }
        }
    }
    {
        ExportRig rig;
        rig.sequence().width = 640;
        rig.sequence().height = 360;
        const AssetId movie = rig.importFile("h264_1080p30.mp4");
        XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
        rig.addClip(rig.v1, movie, 0, 60, kCMTimeZero); // video only
        const std::string path = [self output:@"silent.mov"];
        Outcome outcome = rig.run(
            rig.request(media::VideoCodec::H264, media::ContainerFormat::MOV, media::AudioCodec::AAC, path, 8, 640, 360));
        XCTAssertTrue(outcome.result && outcome.result->ok(), @"%s",
                      outcome.result && !outcome.result->ok() ? outcome.result->error().description().c_str() : "");
        if (outcome.result && outcome.result->ok()) {
            XCTAssertEqual(outcome.result->value().audioFrames, 2 * kRate);
            auto probed = rig.router->probe(path);
            const media::TrackInfo *track = probed.ok() ? probed->info.firstTrack(media::TrackKind::Audio) : nullptr;
            XCTAssertTrue(track != nullptr, @"an audio track is written");
            if (track) {
                XCTAssertEqualWithAccuracy(CMTimeGetSeconds(track->duration), 2.0, 1.0 / kRate + 1e-9);
            }
            const std::vector<float> audio = decodeAudio(*rig.router, path);
            XCTAssertLessThanOrEqual(std::llabs(int64_t(audio.size() / 2) - 2 * kRate), 1);
            float peak = 0;
            for (float v : audio) {
                peak = std::max(peak, std::fabs(v));
            }
            XCTAssertLessThan(peak, 1e-4f, @"silence");
        }
    }
}

@end
