// ExportJob end to end on the generated burn-in media (Scripts/make_test_media.swift): a two-video-
// track sequence with a cross dissolve, a picture-in-picture still, an audio fade in, a gain change
// and a fade out is exported with every preset this machine has, and the file is decoded again
// with the phase-2 decoders: burn-in frame indices at 20 sampled frames (5 inside the dissolve,
// where the blend ratio must equal the frame-centre mix), the PiP layer, the beep's sample
// position, the audio RMS of the fades against a reference computed from the source media, exact
// durations, colour tags and the encoder's hardware flag against VideoToolbox's own answer. Plus
// cancel (prompt, no partial file), refusals before any file exists (missing media, unwritable
// output), an undecodable frame failing the export, memory over a 300-frame 1080p export, and
// progress pacing.

#import <XCTest/XCTest.h>

#include "../../Engine/Export/ExportJob.h"
#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/FFmpeg/FFVideoEncoder.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "../../Engine/Model/Validation.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"
#include "../Media/VideoToolboxProbe.h"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
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

/// What one export reported.
struct Outcome {
    std::optional<media::Result<ex::ExportSummary>> result;
    std::vector<std::pair<double, ex::ExportProgress>> progress; // delivery time, report
    double completedAt = 0;
    double cancelledAt = 0;
    bool fileExistedAtCancel = false;
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
        queue = dispatch_queue_create("com.justjohn12345.videdit.tests.export-callbacks", DISPATCH_QUEUE_SERIAL);
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

/// Exports the sync sequence and checks the file (see the file comment). `fullAudio` checks the
/// beep and the fade RMS (sample-exact containers); otherwise only the audio length.
- (void)exportSyncWithCodec:(media::VideoCodec)codec
                  container:(media::ContainerFormat)container
                      audio:(media::AudioCodec)audioCodec
                   bitDepth:(int)bitDepth
                       name:(NSString *)name
                  fullAudio:(BOOL)fullAudio {
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
    XCTAssertEqualWithAccuracy(audioSeconds, 5.0, fullAudio ? 1.0 / kRate : 0.001, @"%@ audio", name);
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
    XCTAssertLessThanOrEqual(std::llabs(frames - 5 * kRate), fullAudio ? 1 : 48, @"%@ audio frames %lld", name, frames);
    if (!fullAudio || frames < 5 * kRate - 1) {
        return;
    }
    auto onset = test::findBeepOnset(out.data(), frames, 2, kRate);
    XCTAssertTrue(onset.has_value(), @"%@: beep", name);
    if (onset) {
        const double expected = (72000.0 + test::kBeepDetectorLatencyFrames48k) / kRate;
        XCTAssertLessThanOrEqual(std::fabs(*onset - expected) * kRate, 1.0 + 1e-6, @"%@ beep at sample %.1f", name,
                                 *onset * kRate);
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
                    fullAudio:YES];
}

- (void)testHEVCExportRoundTrip {
    [self exportSyncWithCodec:media::VideoCodec::HEVC
                    container:media::ContainerFormat::MOV
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_hevc.mov"
                    fullAudio:YES];
}

- (void)testHEVCMain10ExportRoundTrip {
    const auto availability = media::HardwareCaps::encoderAvailability(media::fourcc::HEVC, 1920, 1080, true);
    if (!availability.hardware && !availability.software) {
        XCTSkip(@"VideoToolbox offers no HEVC Main10 encoder at 1920x1080: %s", availability.reason.c_str());
    }
    [self exportSyncWithCodec:media::VideoCodec::HEVC
                    container:media::ContainerFormat::MP4
                        audio:media::AudioCodec::AAC
                     bitDepth:10
                         name:@"sync_hevc10.mp4"
                    fullAudio:YES];
}

- (void)testProResExportRoundTrip {
    const auto availability = media::HardwareCaps::encoderAvailability(media::fourcc::ProRes422, 1920, 1080, false);
    if (!availability.hardware && !availability.software) {
        XCTSkip(@"VideoToolbox offers no ProRes 422 encoder: %s", availability.reason.c_str());
    }
    [self exportSyncWithCodec:media::VideoCodec::ProRes422
                    container:media::ContainerFormat::MOV
                        audio:media::AudioCodec::LinearPCM
                     bitDepth:8
                         name:@"sync_prores.mov"
                    fullAudio:YES];
}

- (void)testAV1ExportRoundTrip {
    if (!media::ffmpeg::FFVideoEncoder::isAvailable(media::VideoCodec::AV1)) {
        XCTSkip(@"this FFmpeg build has no SVT-AV1 encoder (Scripts/build-ffmpeg.sh with ENABLE_SVTAV1=0)");
    }
    [self exportSyncWithCodec:media::VideoCodec::AV1
                    container:media::ContainerFormat::MP4
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_av1.mp4"
                    fullAudio:YES];
}

- (void)testAV1MatroskaExport {
    if (!media::ffmpeg::FFVideoEncoder::isAvailable(media::VideoCodec::AV1)) {
        XCTSkip(@"this FFmpeg build has no SVT-AV1 encoder (Scripts/build-ffmpeg.sh with ENABLE_SVTAV1=0)");
    }
    // Matroska stores millisecond timestamps: durations and the audio length are checked to 1 ms.
    [self exportSyncWithCodec:media::VideoCodec::AV1
                    container:media::ContainerFormat::MKV
                        audio:media::AudioCodec::AAC
                     bitDepth:8
                         name:@"sync_av1.mkv"
                    fullAudio:NO];
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
                                      o.fileExistedAtCancel = fileExists(job.request().outputPath);
                                      o.cancelledAt = nowSeconds();
                                      job.cancel();
                                  }
                              });
    XCTAssertTrue(outcome.result.has_value());
    XCTAssertGreaterThan(outcome.cancelledAt, 0.0, @"the export was cancelled mid-way");
    XCTAssertTrue(outcome.fileExistedAtCancel, @"writing had begun when it was cancelled");
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
    XCTAssertFalse(fileExists(path), @"the partial file is deleted");
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

- (void)testMemoryIsStableOver300FramesAt1080pSurvivesPressureAndProgressIsPaced {
    ExportRig rig;
    [self buildLongSequence:rig];
    // MOV: AVAssetWriter writes QuickTime media data into the file as it goes (an MP4 is staged
    // elsewhere and moved into place at the end, so its size only shows then).
    const std::string path = [self output:@"long.mov"];
    // Halfway, the system reports critical memory pressure: the job drops its compositor scratch
    // memory and the cache owner purges every unpinned frame (the pool re-decodes what the next
    // frames need); the export must go on and complete.
    auto cache = rig.cache;
    Outcome outcome = rig.run(
        rig.request(media::VideoCodec::H264, media::ContainerFormat::MOV, media::AudioCodec::AAC, path), {},
        [cache](ex::ExportJob &job, const ex::ExportProgress &p, Outcome &o) {
            if (p.framesDone >= 150 && !o.pressureApplied) {
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
    NSLog(@"EXPORT 300 frames H.264 1080p: %.1f fps (%.2f s), %s", summary.averageFps, summary.wallSeconds,
          summary.videoEncoder.c_str());
    XCTAssertEqual(summary.frames, 300);

    // Footprint: after the first ~60 frames (pools warm) it must stay flat.
    uint64_t baseline = 0;
    uint64_t peak = 0;
    for (size_t i = 0; i < outcome.progress.size(); ++i) {
        if (outcome.progress[i].second.framesDone >= 60) {
            if (baseline == 0) {
                baseline = outcome.footprints[i];
            }
            peak = std::max(peak, outcome.footprints[i]);
        }
    }
    if (baseline > 0) {
        const double growthMB = (double(peak) - double(baseline)) / (1024.0 * 1024.0);
        NSLog(@"EXPORT memory: baseline %.1f MB, peak %.1f MB (+%.1f MB)", baseline / 1048576.0, peak / 1048576.0,
              growthMB);
        XCTAssertLessThan(growthMB, 48.0, @"memory grew during the export");
    }

    // Progress: at most 10 deliveries per second, increasing, with plausible numbers.
    for (size_t i = 1; i < outcome.progress.size(); ++i) {
        const double gap = outcome.progress[i].first - outcome.progress[i - 1].first;
        XCTAssertGreaterThanOrEqual(gap, 0.095, @"progress delivered %.3f s after the previous one", gap);
        XCTAssertGreaterThanOrEqual(outcome.progress[i].second.framesDone, outcome.progress[i - 1].second.framesDone);
    }
    if (outcome.progress.size() >= 2) {
        const ex::ExportProgress &late = outcome.progress.back().second;
        XCTAssertEqual(late.totalFrames, 300);
        XCTAssertGreaterThan(late.framesPerSecond, 0.0);
        XCTAssertGreaterThanOrEqual(late.etaSeconds, 0.0);
        XCTAssertGreaterThan(late.bytesWritten, 0u);
    }
}

@end
