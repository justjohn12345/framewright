#include "ExportJob.h"

#include "../Audio/OfflineAudioRenderer.h"
#include "../Media/DecodePool.h"
#include "../Playback/PlaybackController.h"
#include "../Render/Compositor.h"
#include "../Render/Scheduler.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <deque>
#include <set>
#include <string>
#include <vector>

namespace ve::exporting {

using media::MediaErrorCode;
using media::Result;
using media::Status;
using media::makeError;
using media::okStatus;

namespace {

double now() {
    return CACurrentMediaTime();
}

uint64_t fileSize(const std::string &path) {
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0 ? static_cast<uint64_t>(st.st_size) : 0;
}

std::string displayName(const MediaAsset &asset) {
    return asset.name.empty() ? playback::mediaPathForURL(asset.url) : asset.name;
}

std::string secondsText(CMTime t) {
    char text[32];
    std::snprintf(text, sizeof text, "%.3f s", CMTIME_IS_NUMERIC(t) ? CMTimeGetSeconds(t) : 0.0);
    return text;
}

/// Refreshes in a row of a settled stream that made no progress before a missing picture fails the
/// export.
constexpr int kMaxFruitlessRefreshes = 3;

/// Frames of the export: the sequence duration on its frame grid (rounded up).
int64_t frameCount(const Sequence &sequence) {
    const CMTime duration = sequence.duration();
    if (!(duration > kCMTimeZero) || !isPositive(sequence.frameDuration)) {
        return 0;
    }
    return frameIndexAt(duration, sequence.frameDuration, SnapMode::Ceil);
}

/// Opens `path` for writing without leaving anything behind: an existing file is opened as is
/// (not truncated), a new one is created exclusively and removed again.
Status checkWritable(const std::string &path) {
    int fd = ::open(path.c_str(), O_WRONLY);
    if (fd >= 0) {
        ::close(fd);
        return okStatus();
    }
    if (errno != ENOENT) {
        return makeError(MediaErrorCode::PermissionDenied, "cannot write to " + path + ": " + std::strerror(errno));
    }
    fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        return makeError(MediaErrorCode::PermissionDenied, "cannot create " + path + ": " + std::strerror(errno));
    }
    ::close(fd);
    ::unlink(path.c_str());
    return okStatus();
}

std::string canonicalPath(const std::string &path) {
    char resolved[PATH_MAX];
    return ::realpath(path.c_str(), resolved) != nullptr ? std::string(resolved) : path;
}

/// Whether `a` and `b` name the same file: the same inode when both exist, else the same
/// canonical path.
bool sameFile(const std::string &a, const std::string &b) {
    struct stat sa {};
    struct stat sb {};
    if (::stat(a.c_str(), &sa) == 0 && ::stat(b.c_str(), &sb) == 0) {
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
    }
    return canonicalPath(a) == canonicalPath(b);
}

NSURL *fileURL(const std::string &path) {
    return [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()] isDirectory:NO];
}

std::string describeNSError(NSError *error) {
    return error != nil ? std::string(error.localizedDescription.UTF8String ?: "unknown error") : "unknown error";
}

/// The file an export is written to until it is complete: `path` inside a fresh directory from
/// NSItemReplacementDirectory for the destination (on the destination's volume, and one a
/// sandboxed app may write for a URL the save panel granted), with the destination's name so the
/// container is recognised by its extension. The destination is only touched once the file is
/// complete (replace()), so a cancelled or failed export leaves the user's existing file as it
/// was. discard() deletes the directory with whatever is in it.
struct WorkingFile {
    std::string directory;
    std::string path;

    static Result<WorkingFile> create(const std::string &destination) {
        @autoreleasepool {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSURL *dest = fileURL(destination);
            NSError *error = nil;
            NSURL *dir = [fm URLForDirectory:NSItemReplacementDirectory
                                    inDomain:NSUserDomainMask
                           appropriateForURL:dest
                                      create:YES
                                       error:&error];
            if (dir == nil) {
                // Some volumes have no replacement directory for a file that does not exist yet;
                // ask for its folder's.
                NSError *folderError = nil;
                dir = [fm URLForDirectory:NSItemReplacementDirectory
                                 inDomain:NSUserDomainMask
                        appropriateForURL:dest.URLByDeletingLastPathComponent
                                   create:YES
                                    error:&folderError];
            }
            if (dir == nil) {
                return makeError(MediaErrorCode::PermissionDenied,
                                 "cannot create a temporary file next to " + destination + ": " + describeNSError(error));
            }
            WorkingFile file;
            file.directory = dir.path.fileSystemRepresentation;
            file.path = [dir URLByAppendingPathComponent:dest.lastPathComponent isDirectory:NO].path.fileSystemRepresentation;
            return file;
        }
    }

    void discard() const {
        if (!directory.empty()) {
            @autoreleasepool {
                [NSFileManager.defaultManager removeItemAtPath:[NSString stringWithUTF8String:directory.c_str()]
                                                         error:nil];
            }
        }
    }

    /// Moves the complete file to `destination`, replacing a file there (atomically, keeping the
    /// original's identity and attributes where the file system can), then removes the directory.
    Status replace(const std::string &destination) const {
        @autoreleasepool {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSURL *dest = fileURL(destination);
            NSURL *source = fileURL(path);
            NSError *error = nil;
            BOOL moved = NO;
            if (![fm fileExistsAtPath:dest.path]) {
                moved = [fm moveItemAtURL:source toURL:dest error:&error];
            }
            if (!moved && [fm fileExistsAtPath:dest.path]) {
                // An existing file (or one that appeared meanwhile): replace it.
                NSURL *resulting = nil;
                error = nil;
                moved = [fm replaceItemAtURL:dest
                               withItemAtURL:source
                              backupItemName:nil
                                     options:0
                            resultingItemURL:&resulting
                                       error:&error];
            }
            discard();
            if (!moved) {
                return makeError(MediaErrorCode::WriteFailed,
                                 "could not save the finished file as " + destination + ": " + describeNSError(error));
            }
            return okStatus();
        }
    }
};

/// The settings the job actually writes (frame duration and input format filled in).
media::EncodeSettings effectiveSettings(const ExportRequest &request, const Sequence &sequence) {
    media::EncodeSettings encode = request.encode;
    if (encode.video) {
        encode.video->frameDuration = sequence.frameDuration;
        encode.video->inputPixelFormat = ExportJob::pixelFormatFor(encode.video->codec, request.videoBitDepth);
    }
    return encode;
}

} // namespace

// MARK: - Run: one export's working state

struct ExportJob::Run {
    ExportJob &job;
    const Project &project;
    const Sequence &sequence;
    const CMTime frameDuration;
    const int64_t totalFrames;
    media::EncodeSettings encode;

    std::unique_ptr<render::Compositor> compositor;
    std::shared_ptr<media::DecodePool> pool;
    std::unique_ptr<audio::OfflineAudioRenderer> audio;
    media::RoutedWriter writer;

    // Video pull state (the writer's video thread).
    int64_t next = 0;               // next sequence frame to render
    int64_t lookaheadFrames = 1;    // graphs kept ahead of `next` (decode targets)
    std::deque<RenderGraph> upcoming; // graphs of frames next, next + 1, ...
    std::vector<media::FrameCache::PinnedFrame> pins;
    std::vector<render::TextureSet> textures;

    // Audio pull state (the writer's audio thread).
    int64_t audioFramesDone = 0;

    Run(ExportJob &j, const Project &p, const Sequence &s)
        : job(j), project(p), sequence(s), frameDuration(s.frameDuration), totalFrames(frameCount(s)),
          encode(effectiveSettings(j.request_, s)) {}

    bool cancelled() const { return job.cancelled_.load(std::memory_order_acquire); }

    RenderGraph graphAt(int64_t index) const {
        return Scheduler::renderGraphAt(sequence, project, timeForFrame(index, frameDuration));
    }

    Status setUp() {
        const ExportServices &services = job.services_;
        id<MTLDevice> device = services.device ?: MTLCreateSystemDefaultDevice();
        if (device == nil) {
            return makeError(MediaErrorCode::Internal, "no Metal device to render the export with");
        }
        if (encode.video) {
            auto created = render::Compositor::create(device, {MTLPixelFormatRGBA16Float});
            if (!created.ok()) {
                return std::move(created).error();
            }
            compositor = std::move(created).value();

            media::DecodePool::Config config;
            config.lookahead = job.options_.decodeLookahead;
            config.budgetFraction = job.options_.poolBudgetFraction;
            pool = std::make_shared<media::DecodePool>(services.router, services.cache, config);
            for (const MediaAsset &asset : project.assets) {
                if (!asset.hasVideo()) {
                    continue;
                }
                std::optional<media::RoutedMediaInfo> routed;
                if (auto it = services.routing.find(asset.id); it != services.routing.end()) {
                    routed = it->second;
                }
                pool->registerAsset(asset.id, playback::mediaPathForURL(asset.url), std::move(routed));
            }
            lookaheadFrames = std::max<int64_t>(
                1, static_cast<int64_t>(std::ceil(CMTimeGetSeconds(job.options_.decodeLookahead) /
                                                  CMTimeGetSeconds(frameDuration))));
            for (int64_t i = 0; i <= lookaheadFrames && i < totalFrames; ++i) {
                upcoming.push_back(graphAt(i));
            }
        }
        if (encode.audio) {
            audio::OfflineAudioRenderer::Config config;
            config.sampleRate = encode.audio->sampleRate;
            config.channels = encode.audio->channels;
            audio = std::make_unique<audio::OfflineAudioRenderer>(services.router, job.request_.project,
                                                                  job.request_.sequenceId, services.routing, config);
        }
        return okStatus();
    }

    /// Decode targets for the frames in `upcoming`: each clip at its first visible source time,
    /// the frame being rendered first (upper layers first), then by proximity.
    void retarget() {
        std::vector<media::DecodeTarget> targets;
        std::vector<ClipId> seen;
        for (size_t k = 0; k < upcoming.size(); ++k) {
            const RenderGraph &graph = upcoming[k];
            for (size_t i = 0; i < graph.layers.size(); ++i) {
                const VideoLayer &layer = graph.layers[i];
                if (std::find(seen.begin(), seen.end(), layer.clipId) != seen.end()) {
                    continue;
                }
                seen.push_back(layer.clipId);
                media::DecodeTarget target;
                target.asset = layer.assetId;
                // The start of the slot the picture is looked up by (see frameSlotTimeFor).
                const MediaAsset *asset = project.findAsset(layer.assetId);
                target.sourceTime = asset ? playback::frameSlotTimeFor(layer, *asset) : layer.sourceTime;
                target.priority = static_cast<int>(10000 - static_cast<int64_t>(k) * 10 + static_cast<int64_t>(i));
                target.lane = layer.clipId.value();
                targets.push_back(std::move(target));
            }
        }
        pool->setTargets(std::move(targets));
    }

    /// Waits until the picture of `layer` is decoded and maps it (see the header comment).
    Status waitForPicture(const VideoLayer &layer, int64_t frameIndex, media::FrameCache::PinnedFrame &pin,
                          render::TextureSet &texture) {
        media::FrameCache &cache = *job.services_.cache;
        const MediaAsset *asset = project.findAsset(layer.assetId);
        if (asset == nullptr) {
            return makeError(MediaErrorCode::InvalidState, "a clip refers to an asset that is not in the project");
        }
        const int64_t slot = playback::frameSlotFor(layer, *asset);
        const auto deadline = std::chrono::steady_clock::now() + job.options_.frameTimeout;
        // Refreshes that found the stream exactly where the previous one left it (no frame
        // decoded, no seek in between): only such refreshes in a row count towards giving up, so
        // repeated memory purges between a decode and the lookup below cannot fail an export that
        // progresses.
        int fruitlessRefreshes = 0;
        std::optional<std::pair<uint64_t, uint64_t>> lastRefreshMark; // (framesDecoded, seeks)
        auto describe = [&](const std::string &what) {
            return "Frame " + std::to_string(frameIndex) + " (" + secondsText(timeForFrame(frameIndex, frameDuration)) +
                   ") cannot be exported: “" + displayName(*asset) + "” " + what;
        };
        for (;;) {
            pin = cache.acquire(layer.assetId, slot);
            if (pin) {
                auto mapped = compositor->textureCache().textures(pin.image());
                if (!mapped.ok()) {
                    return makeError(mapped.error().code,
                                     describe("decoded to a picture the GPU cannot read: " + mapped.error().message));
                }
                texture = std::move(mapped).value();
                return okStatus();
            }
            if (cancelled()) {
                return makeError(MediaErrorCode::Cancelled, "Export cancelled");
            }
            std::optional<media::DecodePool::StreamStats> stream;
            for (media::DecodePool::StreamStats &s : pool->stats().streams) {
                if (s.asset == layer.assetId && s.lane == layer.clipId.value()) {
                    stream = std::move(s);
                    break;
                }
            }
            if (stream && (stream->idle || stream->failed)) {
                // The step that settled the stream may have published the picture after the
                // lookup above.
                if (cache.contains(layer.assetId, slot)) {
                    continue;
                }
                if (stream->failed || stream->error) {
                    const std::string reason = stream->error ? stream->error->description() : "the decoder failed";
                    return makeError(stream->error ? stream->error->code : MediaErrorCode::DecodeFailed,
                                     describe("could not be decoded at source time " + secondsText(layer.sourceTime) +
                                              " (" + reason + ")"));
                }
                // Settled without the picture: it was evicted after decoding (memory pressure), or
                // the media has no picture there. Ask the pool to look again; give up after
                // refreshes that made no progress at all.
                const std::pair<uint64_t, uint64_t> mark{stream->framesDecoded, stream->seeks};
                if (lastRefreshMark && *lastRefreshMark == mark) {
                    ++fruitlessRefreshes;
                } else if (lastRefreshMark) {
                    fruitlessRefreshes = 0; // the stream moved since: start counting again
                }
                if (fruitlessRefreshes >= kMaxFruitlessRefreshes) {
                    std::string where = "has no picture at source time " + secondsText(layer.sourceTime);
                    if (stream->eof) {
                        where += isNumeric(stream->videoEnd)
                                     ? ": its video ends at " + secondsText(stream->videoEnd)
                                     : ": its video ends before that";
                    }
                    return makeError(MediaErrorCode::DecodeFailed, describe(where));
                }
                lastRefreshMark = mark;
                pool->refresh();
            }
            if (std::chrono::steady_clock::now() >= deadline) {
                return makeError(MediaErrorCode::Timeout,
                                 describe("was not decoded within " +
                                          std::to_string(job.options_.frameTimeout.count() / 1000) + " s"));
            }
            pool->waitForProgress(std::chrono::milliseconds(20));
        }
    }

    Result<std::optional<media::VideoInput>> nextVideo() {
        @autoreleasepool {
            if (cancelled()) {
                return makeError(MediaErrorCode::Cancelled, "Export cancelled");
            }
            if (next >= totalFrames) {
                pool->setTargets({});
                return std::optional<media::VideoInput>{};
            }
            if (job.memoryPressure_.exchange(false, std::memory_order_acq_rel)) {
                compositor->releaseScratchMemory();
            }
            retarget();
            const RenderGraph &graph = upcoming.front();
            const size_t n = graph.layers.size();
            pins.clear();
            pins.resize(n);
            textures.assign(n, render::TextureSet{});
            for (size_t i = 0; i < n; ++i) {
                VE_MEDIA_TRY(waitForPicture(graph.layers[i], next, pins[i], textures[i]));
            }
            auto buffer = writer.writer->makePixelBuffer();
            if (!buffer.ok()) {
                return std::move(buffer).error();
            }
            const media::PixelBuffer image = std::move(buffer).value();
            auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &out) {
                if (index >= textures.size() || !textures[index]) {
                    return false;
                }
                out = textures[index];
                return true;
            };
            auto rendered = compositor->renderAndWait(graph, lookup, render::PixelBufferTarget{image});
            pins.clear();
            textures.clear();
            if (!rendered.ok()) {
                return makeError(rendered.error().code, "Compositing frame " + std::to_string(next) +
                                                            " failed: " + rendered.error().message);
            }
            if (!rendered->status.ok()) {
                return makeError(rendered->status.error().code, "The GPU failed on frame " + std::to_string(next) +
                                                                    ": " + rendered->status.error().message);
            }
            if (!rendered->skippedLayers.empty()) {
                return makeError(MediaErrorCode::Internal, "Frame " + std::to_string(next) +
                                                               " was composited without one of its layers");
            }
            const CMTime pts = timeForFrame(next, frameDuration);
            ++next;
            upcoming.pop_front();
            const int64_t ahead = next + static_cast<int64_t>(upcoming.size());
            if (ahead < totalFrames) {
                upcoming.push_back(graphAt(ahead));
            }
            job.noteProgress(next, totalFrames);
            return std::optional<media::VideoInput>{media::VideoInput{image, pts}};
        }
    }

    Result<int> nextAudio(float *dst, int maxFrames) {
        @autoreleasepool {
            auto rendered = audio->render(dst, maxFrames, [this] { return cancelled(); });
            if (!rendered.ok()) {
                return std::move(rendered).error();
            }
            audioFramesDone += rendered.value();
            if (!encode.video) {
                // Audio-only export: progress in sequence frames of audio.
                const double seconds = static_cast<double>(audioFramesDone) / audio->sampleRate();
                job.noteProgress(std::min<int64_t>(totalFrames, static_cast<int64_t>(seconds /
                                                                                     CMTimeGetSeconds(frameDuration))),
                                 totalFrames);
            }
            return rendered.value();
        }
    }

    Result<ExportSummary> execute() {
        const std::string &destination = job.request_.outputPath;
        const double started = now();
        VE_MEDIA_TRY(setUp());
        auto made = job.services_.router->makeWriter(encode);
        if (!made.ok()) {
            return std::move(made).error();
        }
        writer = std::move(made).value();
        auto created = WorkingFile::create(destination);
        if (!created.ok()) {
            return makeError(created.error().code, "Could not start writing " + destination + ": " +
                                                       created.error().message);
        }
        const WorkingFile working = std::move(created).value();
        job.setWorkingPath(working.path);
        // Every way out below that is not a success discards the working file only: the
        // destination is not touched until the file is complete.
        auto abandon = [&](media::MediaError error) -> Result<ExportSummary> {
            writer.writer->cancel();
            working.discard();
            return error;
        };
        if (Status opened = writer.writer->open(working.path, encode); !opened.ok()) {
            return abandon(makeError(opened.error().code,
                                     "Could not start writing " + destination + ": " + opened.error().message));
        }
        media::VideoPullFn video;
        media::AudioPullFn audioPull;
        if (encode.video) {
            video = [this] { return nextVideo(); };
        }
        if (encode.audio) {
            audioPull = [this](float *dst, int maxFrames) { return nextAudio(dst, maxFrames); };
        }
        Status pulled = writer.writer->runPull(video, audioPull);
        if (pool) {
            pool->setTargets({}); // stop decoding ahead
        }
        if (!pulled.ok() || cancelled()) {
            return abandon(cancelled() ? makeError(MediaErrorCode::Cancelled, "Export cancelled") : pulled.error());
        }
        // finish() can take a while (the MP4 index rewrite); a cancel meanwhile abandons it.
        writer.writer->setFinishCancellation([this] { return cancelled(); });
        if (Status finished = writer.writer->finish(); !finished.ok()) {
            if (cancelled() || finished.error().code == MediaErrorCode::Cancelled) {
                return abandon(makeError(MediaErrorCode::Cancelled, "Export cancelled"));
            }
            return abandon(makeError(finished.error().code, "Could not finish writing " + destination + ": " +
                                                                finished.error().message));
        }
        if (cancelled()) { // a cancel that came as finish() returned still means "no new file"
            working.discard();
            return makeError(MediaErrorCode::Cancelled, "Export cancelled");
        }
        const uint64_t bytes = fileSize(working.path);
        if (Status replaced = working.replace(destination); !replaced.ok()) {
            return makeError(replaced.error().code, "The export could not be saved: " + replaced.error().message);
        }
        ExportSummary summary;
        summary.path = destination;
        summary.frames = encode.video ? next : totalFrames;
        summary.duration = CMTimeMultiply(frameDuration, static_cast<int32_t>(totalFrames));
        summary.audioFrames = audioFramesDone;
        summary.bytes = fileSize(destination);
        if (summary.bytes == 0) {
            summary.bytes = bytes; // the destination is not stat-able (unlikely): the size written
        }
        summary.writerBackend = writer.backend;
        summary.videoEncoder = writer.writer->videoEncoderName();
        summary.hardwareEncoder = encode.video && writer.writer->usesHardwareVideoEncoder();
        summary.width = encode.video ? encode.video->width : 0;
        summary.height = encode.video ? encode.video->height : 0;
        summary.wallSeconds = now() - started;
        summary.averageFps = summary.wallSeconds > 0 ? static_cast<double>(summary.frames) / summary.wallSeconds : 0;
        return summary;
    }
};

// MARK: - ExportJob

OSType ExportJob::pixelFormatFor(media::VideoCodec codec, int bitDepth) {
    switch (codec) {
    case media::VideoCodec::ProRes422:
        return kCVPixelFormatType_32BGRA;
    case media::VideoCodec::HEVC:
    case media::VideoCodec::AV1:
        return bitDepth >= 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                              : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    case media::VideoCodec::H264:
        break;
    }
    return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

Status ExportJob::validate(const ExportRequest &request, const ExportServices &services) {
    if (!request.project) {
        return makeError(MediaErrorCode::InvalidArgument, "There is no project to export.");
    }
    const Sequence *sequence = request.project->findSequence(request.sequenceId);
    if (sequence == nullptr) {
        return makeError(MediaErrorCode::InvalidArgument, "The sequence to export does not exist.");
    }
    if (frameCount(*sequence) <= 0) {
        return makeError(MediaErrorCode::InvalidArgument, "The sequence is empty: there is nothing to export.");
    }
    if (!services.router || !services.cache) {
        return makeError(MediaErrorCode::InvalidArgument, "The export needs a router and a frame cache.");
    }
    if (services.epoch && *services.epoch != services.cache->epoch()) {
        return makeError(MediaErrorCode::InvalidState, "The project's media changed; start the export again.");
    }
    const media::EncodeSettings &encode = request.encode;
    if (!encode.video && !encode.audio) {
        return makeError(MediaErrorCode::InvalidArgument, "Choose video, audio or both to export.");
    }
    if (encode.video) {
        const media::VideoEncodeSettings &v = *encode.video;
        if (v.width <= 0 || v.height <= 0 || (v.width | v.height) & 1 || v.width > 16384 || v.height > 16384) {
            return makeError(MediaErrorCode::InvalidArgument,
                             "The frame size " + std::to_string(v.width) + "x" + std::to_string(v.height) +
                                 " is not possible: both sides must be even, between 2 and 16384 pixels.");
        }
        if (request.videoBitDepth != 8 && request.videoBitDepth != 10) {
            return makeError(MediaErrorCode::InvalidArgument, "The bit depth must be 8 or 10.");
        }
        if (request.videoBitDepth == 10 && v.codec != media::VideoCodec::HEVC && v.codec != media::VideoCodec::AV1) {
            return makeError(MediaErrorCode::UnsupportedCodec,
                             std::string("10-bit export is available for HEVC and AV1, not ") + toString(v.codec) + ".");
        }
    }
    if (encode.audio && (encode.audio->channels < 1 || encode.audio->sampleRate <= 0)) {
        return makeError(MediaErrorCode::InvalidArgument, "The audio settings are incomplete.");
    }

    const std::string output = request.outputPath;
    if (output.empty() || output.front() != '/') {
        return makeError(MediaErrorCode::InvalidArgument, "The output needs an absolute file path.");
    }
    // The output must not be any of the project's media, used by this sequence or not (another
    // sequence, a clip on a muted track, media only in the bin).
    for (const MediaAsset &asset : request.project->assets) {
        if (sameFile(playback::mediaPathForURL(asset.url), output)) {
            return makeError(MediaErrorCode::InvalidArgument,
                             "The export would overwrite “" + displayName(asset) +
                                 "”, which is media of this project. Choose another file name.");
        }
    }
    // Media: every asset a playing clip uses must be there and readable (FileNotFound either way:
    // it is a media problem, not one of the output).
    std::set<AssetId> checked;
    auto checkTrack = [&](const Track &track) -> Status {
        if (!Scheduler::isTrackActive(*sequence, track)) {
            return okStatus();
        }
        const bool isVideo = track.kind == TrackKind::Video;
        if ((isVideo && !encode.video) || (!isVideo && !encode.audio)) {
            return okStatus();
        }
        for (const Clip &clip : track.clips) {
            if (!checked.insert(clip.assetId).second) {
                continue;
            }
            const MediaAsset *asset = request.project->findAsset(clip.assetId);
            if (asset == nullptr) {
                return makeError(MediaErrorCode::FileNotFound, "A clip on " + track.name +
                                                                   " refers to media that is not in the project.");
            }
            const std::string path = playback::mediaPathForURL(asset->url);
            if (::access(path.c_str(), F_OK) != 0) {
                return makeError(MediaErrorCode::FileNotFound, "“" + displayName(*asset) + "” is missing (" + path +
                                                                   "). Relink it or remove its clips, then export again.");
            }
            if (::access(path.c_str(), R_OK) != 0) {
                return makeError(MediaErrorCode::FileNotFound,
                                 "“" + displayName(*asset) + "” cannot be read (" + path +
                                     "): check its permissions or relink it, then export again.");
            }
        }
        return okStatus();
    };
    for (const Track &track : sequence->videoTracks) {
        VE_MEDIA_TRY(checkTrack(track));
    }
    for (const Track &track : sequence->audioTracks) {
        VE_MEDIA_TRY(checkTrack(track));
    }

    const media::EncodeSettings effective = effectiveSettings(request, *sequence);
    if (services.router->writerBackendFor(effective).empty()) {
        std::string what = effective.video ? media::toString(effective.video->codec) : "";
        if (effective.audio) {
            what += (what.empty() ? "" : " with ") + std::string(media::toString(effective.audio->codec)) + " audio";
        }
        return makeError(MediaErrorCode::UnsupportedCodec,
                         "No encoder can write " + what + " to " + media::toString(effective.container) + ".");
    }
    Status writable = checkWritable(output);
    if (!writable.ok()) {
        return makeError(writable.error().code, "The export cannot be saved there: " + writable.error().message);
    }
    return okStatus();
}

Result<std::shared_ptr<ExportJob>> ExportJob::start(ExportRequest request, ExportServices services,
                                                    ExportOptions options, dispatch_queue_t callbackQueue,
                                                    ProgressHandler progress, CompletionHandler completion) {
    VE_MEDIA_TRY(validate(request, services));
    if (callbackQueue == nullptr || !completion) {
        return makeError(MediaErrorCode::InvalidArgument, "start() needs a callback queue and a completion");
    }
    std::shared_ptr<ExportJob> job(new ExportJob(std::move(request), std::move(services), options, callbackQueue,
                                                 std::move(progress), std::move(completion)));
    {
        std::lock_guard<std::mutex> lock(job->mutex_);
        job->startedAt_ = now();
        const Sequence *sequence = job->request_.project->findSequence(job->request_.sequenceId);
        job->progress_.totalFrames = frameCount(*sequence);
    }
    std::shared_ptr<ExportJob> self = job; // kept alive by the block until the export has ended
    dispatch_async(job->queue_, ^{
      self->run();
    });
    return job;
}

ExportJob::ExportJob(ExportRequest request, ExportServices services, ExportOptions options,
                     dispatch_queue_t callbackQueue, ProgressHandler progress, CompletionHandler completion)
    : request_(std::move(request)), services_(std::move(services)), options_(options), callbackQueue_(callbackQueue),
      queue_(dispatch_queue_create("com.justjohn12345.framewright.export",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                           QOS_CLASS_USER_INITIATED, 0))),
      progressHandler_(std::move(progress)), completion_(std::move(completion)) {}

ExportJob::~ExportJob() = default;

void ExportJob::run() {
    Result<ExportSummary> result = makeError(MediaErrorCode::Internal, "the export did not run");
    {
        const Project &project = *request_.project;
        const Sequence *sequence = project.findSequence(request_.sequenceId);
        // The run (decoders, compositor, mixer, writer) is torn down before the outcome is
        // reported, so a finished export has released everything.
        Run r(*this, project, *sequence);
        result = r.execute();
    }
    finish(std::move(result));
}

void ExportJob::noteProgress(int64_t framesDone, int64_t totalFrames) {
    const double t = now();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        progress_.framesDone = framesDone;
        progress_.totalFrames = totalFrames;
        progress_.elapsedSeconds = t - startedAt_;
        rateSamples_.emplace_back(t, framesDone);
        while (rateSamples_.size() > 2 && rateSamples_.front().first < t - 1.0) {
            rateSamples_.pop_front();
        }
        const auto &[t0, f0] = rateSamples_.front();
        progress_.framesPerSecond = t > t0 ? static_cast<double>(framesDone - f0) / (t - t0) : 0;
        progress_.etaSeconds = progress_.framesPerSecond > 0
                                   ? static_cast<double>(totalFrames - framesDone) / progress_.framesPerSecond
                                   : -1;
        if (lastSizeCheck_ < 0 || t - lastSizeCheck_ >= options_.progressInterval) {
            lastSizeCheck_ = t;
            progress_.bytesWritten = workingPath_.empty() ? 0 : fileSize(workingPath_);
        }
    }
    scheduleProgress();
}

void ExportJob::scheduleProgress() {
    if (!progressHandler_ || completed_.load(std::memory_order_acquire) ||
        progressPending_.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    // Delivered no sooner than progressInterval after the previous delivery, with the numbers
    // current at delivery time (one pending delivery at most).
    const double wait =
        std::max(0.0, lastProgressDelivery_.load(std::memory_order_acquire) + options_.progressInterval - now());
    std::weak_ptr<ExportJob> weak = weak_from_this();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(wait * NSEC_PER_SEC)), callbackQueue_, ^{
      std::shared_ptr<ExportJob> job = weak.lock();
      if (!job) {
          return;
      }
      job->progressPending_.store(false, std::memory_order_release);
      if (job->completed_.load(std::memory_order_acquire)) {
          return;
      }
      job->lastProgressDelivery_.store(now(), std::memory_order_release);
      job->progressHandler_(job->progress());
    });
}

void ExportJob::finish(Result<ExportSummary> result) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        finished_ = true;
        if (result.ok()) {
            progress_.framesDone = progress_.totalFrames;
            progress_.bytesWritten = result->bytes;
            progress_.etaSeconds = 0;
        }
    }
    finishedCv_.notify_all();
    completed_.store(true, std::memory_order_release);
    CompletionHandler completion = std::move(completion_);
    completion_ = nullptr;
    auto shared = std::make_shared<Result<ExportSummary>>(std::move(result));
    dispatch_async(callbackQueue_, ^{
      completion(std::move(*shared));
    });
}

void ExportJob::setWorkingPath(std::string path) {
    std::lock_guard<std::mutex> lock(mutex_);
    workingPath_ = std::move(path);
}

std::string ExportJob::workingPath() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return workingPath_;
}

void ExportJob::cancel() {
    cancelled_.store(true, std::memory_order_release);
}

bool ExportJob::isCancelled() const {
    return cancelled_.load(std::memory_order_acquire);
}

void ExportJob::handleMemoryPressure(bool) {
    memoryPressure_.store(true, std::memory_order_release);
}

ExportProgress ExportJob::progress() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return progress_;
}

bool ExportJob::isFinished() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return finished_;
}

bool ExportJob::waitUntilFinished(std::chrono::milliseconds timeout) const {
    std::unique_lock<std::mutex> lock(mutex_);
    return finishedCv_.wait_for(lock, timeout, [&] { return finished_; });
}

} // namespace ve::exporting
