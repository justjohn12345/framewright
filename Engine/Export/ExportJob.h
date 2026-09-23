// ExportJob: renders one sequence into a movie file.
//
// Data flow (PLAN.md, "Data flow (export)"): for every sequence frame, on the writer's pull
// callbacks, the job
//   1. resolves the frame's RenderGraph with Scheduler::renderGraphAt: the same code path, frame
//      grid and frame-centre dissolve mix as the program monitor;
//   2. waits until every layer's picture is decoded: a private DecodePool (its own lanes, one
//      sequential decoder per clip, never the scrub path) decodes a bounded lookahead into the
//      FrameCache; the job looks pictures up by the slot the program monitor uses
//      (playback::frameSlotFor) and pins them. A frame is never written with a layer missing:
//      a picture that cannot be decoded fails the export (with the decoder's error), it does not
//      become a black or stale layer;
//   3. composites with its own Compositor (RGBA16Float intermediate) into a buffer from the
//      writer's pool in the encoder's input format (pixelFormatFor: '420v' for H.264, HEVC and
//      8-bit AV1, 'x420' for 10-bit HEVC (Main10) and AV1, '32BGRA' for ProRes) with
//      Compositor::renderAndWait; a skipped layer is an error.
// Audio is mixed offline and sample-accurately by an OfflineAudioRenderer (the playback mixer's
// own envelope, crossfade and speed code). Both streams go through IMediaWriter::runPull, which
// ends each stream when its callback reports the end (so audio and video may end at different
// times). The writer comes from BackendRouter::makeWriter (AVAssetWriter for H.264/HEVC/ProRes in
// MOV/MP4; FFmpeg for AV1 and Matroska).
//
// Before anything is written, validate() checks what can be checked (see there); start() runs
// it and creates no file when it fails. After that every failure (decode, encode, write, GPU)
// ends the export with an error that says what went wrong, and the partial file is deleted.
//
// Cancel: cancel() is non-blocking; the pull callbacks notice it within one frame decode or
// 20 ms, the writer abandons and deletes the file, and the completion reports Cancelled (well
// within 500 ms). Memory pressure: handleMemoryPressure() makes the render thread release the
// compositor's scratch memory before its next frame; the frame cache is trimmed by its owner (the
// pool re-decodes a picture that was evicted before the job pinned it).
//
// Progress: frames done / total, frames per second (over the last second), ETA and the output's
// size, delivered on the callback queue at most every ExportOptions::progressInterval (10 Hz),
// coalesced (a slow queue gets the latest numbers, never a backlog), and never after the
// completion. The completion runs exactly once on the callback queue with the summary (duration,
// frames, file size, writer backend, encoder name and whether it ran in hardware, wall time) or
// the error.
//
// Threading: start() from any thread; the export runs on its own serial queue (and the writer's
// internal queues). cancel(), handleMemoryPressure(), progress(), isFinished() and
// waitUntilFinished() are thread-safe. The job keeps itself alive until it has finished, so the
// caller may drop its reference at any time.
#pragma once

#include "../Media/BackendRouter.h"
#include "../Media/FrameCache.h"
#include "../Model/Project.h"

#import <Metal/Metal.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace ve::exporting {

/// What to export and where.
struct ExportRequest {
    std::shared_ptr<const Project> project;
    SequenceId sequenceId;
    /// Container, video and audio settings. The job fills in video->frameDuration (the
    /// sequence's) and video->inputPixelFormat (pixelFormatFor(codec, videoBitDepth)); the
    /// sequence is fitted into video->width x video->height (letterboxed if the aspect differs).
    media::EncodeSettings encode;
    /// 8, or 10 for HEVC Main10 and 10-bit AV1.
    int videoBitDepth = 8;
    /// Absolute POSIX path of the output file (replaced if it exists).
    std::string outputPath;
};

/// The engine services the job uses.
struct ExportServices {
    std::shared_ptr<media::BackendRouter> router;
    /// The frame cache the job's decode pool fills (the engine's shared cache, or a private one).
    std::shared_ptr<media::FrameCache> cache;
    /// Media epoch the project's asset ids belong to (see FrameCache.h); validate() refuses when
    /// the cache is in another one. nullopt: the cache's current epoch.
    std::optional<media::FrameCache::Epoch> epoch;
    /// Routing computed at import, per asset (saves a probe per decoder).
    std::map<AssetId, media::RoutedMediaInfo> routing;
    /// Metal device for compositing; nil: the system default device.
    id<MTLDevice> device = nil;
};

struct ExportOptions {
    /// Share of the cache budget the job's lookahead may fill (DecodePool::Config::budgetFraction;
    /// the engine gives the program monitor 0.5 and the source monitor 0.25).
    double poolBudgetFraction = 0.25;
    /// Decode lookahead per clip (bounded further by the budget share).
    CMTime decodeLookahead = CMTimeMake(1, 2);
    /// Longest wait for one layer's picture before the export fails with Timeout.
    std::chrono::milliseconds frameTimeout{30000};
    /// Minimum time between two progress deliveries, in seconds.
    double progressInterval = 0.1;
};

struct ExportProgress {
    int64_t framesDone = 0;
    int64_t totalFrames = 0;
    double framesPerSecond = 0; ///< Over the last second.
    double etaSeconds = -1;     ///< -1 while unknown.
    /// Current size of the output file. 0 while the writer stages the media elsewhere
    /// (AVAssetWriter writing MP4 with the index up front moves the file into place at the end).
    uint64_t bytesWritten = 0;
    double elapsedSeconds = 0;
};

struct ExportSummary {
    std::string path;
    CMTime duration = kCMTimeZero; ///< Of the exported sequence (frames x frame duration).
    int64_t frames = 0;
    int64_t audioFrames = 0;
    uint64_t bytes = 0;
    std::string writerBackend; ///< "apple" or "ffmpeg".
    std::string videoEncoder;  ///< IMediaWriter::videoEncoderName() ("" without video).
    bool hardwareEncoder = false;
    int width = 0;
    int height = 0;
    double wallSeconds = 0;
    double averageFps = 0;
};

using ProgressHandler = std::function<void(const ExportProgress &)>;
using CompletionHandler = std::function<void(media::Result<ExportSummary>)>;

class ExportJob : public std::enable_shared_from_this<ExportJob> {
  public:
    /// The encoder input format the job renders for `codec` at `bitDepth` (see the header comment).
    static OSType pixelFormatFor(media::VideoCodec codec, int bitDepth);

    /// Checks, without writing anything: the project and sequence exist and the sequence is not
    /// empty; every asset used by a clip on a playing track is in the project and its file exists
    /// and is readable (FileNotFound naming the asset otherwise); the settings are complete and
    /// some writer accepts them (UnsupportedCodec otherwise); the bit depth suits the codec; the
    /// output is not one of the project's media files and can be written (PermissionDenied
    /// otherwise; checked by opening it, which leaves no file behind); the cache is in the
    /// project's media epoch.
    static media::Status validate(const ExportRequest &request, const ExportServices &services);

    /// validate(), then starts the export. On a validation error nothing is created and no
    /// callback runs. Handlers run on `callbackQueue` (progress may be empty).
    static media::Result<std::shared_ptr<ExportJob>> start(ExportRequest request, ExportServices services,
                                                           ExportOptions options, dispatch_queue_t callbackQueue,
                                                           ProgressHandler progress, CompletionHandler completion);

    ~ExportJob();
    ExportJob(const ExportJob &) = delete;
    ExportJob &operator=(const ExportJob &) = delete;

    /// Stops the export as soon as possible and deletes the partial file; the completion then
    /// reports Cancelled (unless the export already finished). Non-blocking; idempotent.
    void cancel();
    bool isCancelled() const;
    /// Asks the render thread to release the compositor's scratch memory before its next frame.
    void handleMemoryPressure(bool critical);

    ExportProgress progress() const;
    /// The export has ended (written, failed or cancelled, with the partial file removed); the
    /// completion is dispatched right after.
    bool isFinished() const;
    bool waitUntilFinished(std::chrono::milliseconds timeout) const;

    const ExportRequest &request() const { return request_; }

    struct Run; // the export's working state (ExportJob.mm)

  private:
    ExportJob(ExportRequest request, ExportServices services, ExportOptions options, dispatch_queue_t callbackQueue,
              ProgressHandler progress, CompletionHandler completion);
    void run();
    /// Records `framesDone` (render thread) and schedules a delivery.
    void noteProgress(int64_t framesDone, int64_t totalFrames);
    void scheduleProgress();
    void finish(media::Result<ExportSummary> result);
    friend struct Run;

    ExportRequest request_;
    const ExportServices services_;
    const ExportOptions options_;
    dispatch_queue_t callbackQueue_;
    dispatch_queue_t queue_;
    const ProgressHandler progressHandler_;
    CompletionHandler completion_;

    std::atomic<bool> cancelled_{false};
    std::atomic<bool> memoryPressure_{false};
    std::atomic<bool> completed_{false};    // completion dispatched: no more progress
    std::atomic<bool> progressPending_{false};
    std::atomic<double> lastProgressDelivery_{0}; // CACurrentMediaTime of the last delivery

    mutable std::mutex mutex_;
    mutable std::condition_variable finishedCv_;
    bool finished_ = false;
    ExportProgress progress_;
    std::deque<std::pair<double, int64_t>> rateSamples_; // (time, frames done) over the last second
    double startedAt_ = 0;
    double lastSizeCheck_ = -1;
};

} // namespace ve::exporting
