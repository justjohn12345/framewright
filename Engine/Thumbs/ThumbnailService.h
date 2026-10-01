// ThumbnailService: asynchronous, cached, coalesced video/still thumbnails as CGImages.
//
// Pipeline per request (asset, time, maxDimension):
//   memory LRU -> disk cache (<dir>/<hash>.png) -> decode.
// Decode opens a video decoder through the BackendRouter with DecodeOptions::maxDimension so
// VideoToolbox scales in the decoder when the backend honours it; the frame is then converted
// (and scaled, if the backend returned a larger frame) to 32BGRA with a VTPixelTransferSession
// (hardware accelerated), the track's display rotation is applied, and the result is copied
// into a CGImage (sRGB, premultiplied BGRA). The PNG is written atomically to the disk cache.
//
// Keys. Memory: (asset, source path, time in microseconds, maxDimension, track, source file size
// and modification time); asset ids restart per project, so the path is part of the key and a new
// project's asset that reuses an id never gets (or joins the decode of) another file's thumbnail,
// even one of the same size and modification time. Disk: a hash of (path, file size, file modification time, time,
// maxDimension, format version). A changed or replaced source file therefore never hits a stale
// thumbnail in either cache, and different projects share thumbnails of the same file.
//
// Bounds: the memory cache by Config::memoryBudgetBytes (LRU), the disk cache by
// Config::diskBudgetBytes (least recently used files deleted, see DiskCacheBudget), the routing
// memo (per file version and routing policy) by Config::maxRoutes entries (LRU), idle decoders by
// Config::maxIdleDecoders.
//
// Coalescing: requests with the same memory key share one decode; every waiter is called.
//
// Threading: public methods are thread-safe and never block on decoding (request() stats the
// source file for its key). Work runs on Config::threads worker threads (std::thread; decoders
// block on I/O; every job runs in its own autorelease pool). Callbacks are
// dispatch_async'ed onto the queue given with each request; they never run inline and never
// capture the service, so they may run after the service is destroyed. Every callback is
// invoked exactly once: with the image, an error, or MediaErrorCode::Cancelled (cancelPending()
// or destruction before the work started). The destructor waits for decodes in flight.
#pragma once

#include "../Media/BackendRouter.h"
#include "../Media/CFRef.h"
#include "../Media/PixelBuffer.h"
#include "../Model/Ids.h"

#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ve::thumbs {

class DiskCacheBudget; // CacheKey.h

struct ThumbnailRequest {
    AssetId asset;
    std::string url;
    CMTime time = kCMTimeZero; ///< Source time; clamped into the media (past the end: last frame).
    int maxDimension = 160;    ///< Longest side of the result in pixels (> 0).
    int trackIndex = -1;       ///< Video/still track of the routed info; -1 = first.
};

using ThumbnailImage = media::CFRef<CGImageRef>;
using ThumbnailCallback = std::function<void(media::Result<ThumbnailImage>)>;

class ThumbnailService {
  public:
    struct Config {
        /// Directory for PNG files; created on demand. Empty disables the disk cache.
        std::string diskCacheDirectory;
        /// Disk cache bound (0 = unbounded).
        uint64_t diskBudgetBytes = uint64_t(256) << 20;
        size_t memoryBudgetBytes = size_t(64) << 20;
        /// Routing decisions remembered (per file version), least recently used dropped.
        size_t maxRoutes = 64;
        int threads = 2;
        /// Open decoders kept for reuse (per (path, track, maxDimension)); timeline strips ask
        /// for many times of one asset in a row.
        int maxIdleDecoders = 4;
        /// Routing for every decode. Empty (the default): the router's default policy at the time of
        /// each decode, so the app's "Prefer FFmpeg for decode" setting is followed, also when it
        /// changes while the service runs (routing decisions and idle decoders are kept per policy).
        std::optional<media::RoutingPolicy> routing{};
    };

    struct Stats {
        uint64_t requests = 0;
        uint64_t memoryHits = 0;
        uint64_t diskHits = 0;
        uint64_t decodes = 0;
        uint64_t coalesced = 0;
        uint64_t cancelled = 0;
        uint64_t failures = 0;
        uint64_t diskWriteFailures = 0;
        size_t memoryBytes = 0;
        size_t memoryCount = 0;
        size_t routeCount = 0; ///< Routing decisions remembered (<= Config::maxRoutes).
    };

    ThumbnailService(std::shared_ptr<media::BackendRouter> router, Config config);
    ~ThumbnailService();
    ThumbnailService(const ThumbnailService &) = delete;
    ThumbnailService &operator=(const ThumbnailService &) = delete;

    /// Requests a thumbnail; `callback` runs on `queue` (a memory hit is also delivered
    /// asynchronously). InvalidArgument for an empty path, a non-positive size or a null queue.
    void request(const ThumbnailRequest &request, dispatch_queue_t queue, ThumbnailCallback callback);
    /// Cancels requests of `asset` that have not started decoding (callbacks get Cancelled).
    void cancelPending(AssetId asset);
    /// Drops `asset`'s images from the memory cache (the disk cache is keyed by file content).
    void purge(AssetId asset);

    Stats stats() const;

    /// Blocks until no request is queued and no worker is decoding (and writing its disk cache file), or `timeout`;
    /// false on timeout. Callbacks of finished work may still be on their way to their queues. For
    /// tests (which delete the cache directory afterwards) and orderly shutdown.
    bool waitUntilIdle(std::chrono::milliseconds timeout);

    /// Disk cache file name for a request (exposed for tests and cache management).
    static std::string diskFileName(const ThumbnailRequest &request);

    /// The conversion step on its own: scales `frame` (any decoder output format) to fit
    /// `maxDimension`, converts it to BGRA and applies a clockwise display rotation.
    static media::Result<ThumbnailImage> renderThumbnail(const media::PixelBuffer &frame, int maxDimension,
                                                         int rotationDegrees);

  private:
    struct Key {
        AssetId asset;
        std::string url; ///< Asset ids restart per project: the file is part of the identity.
        int64_t micros = 0;
        int maxDimension = 0;
        int trackIndex = -1;
        uint64_t fileSize = 0;       ///< Source file identity: a replaced file is a new key.
        int64_t fileModified = 0;
        friend auto operator<=>(const Key &, const Key &) = default;
    };
    struct Waiter {
        dispatch_queue_t queue;
        ThumbnailCallback callback;
    };
    struct Job {
        Key key;
        ThumbnailRequest request;
        std::vector<Waiter> waiters;
    };
    struct CacheEntry {
        ThumbnailImage image;
        size_t bytes = 0;
        std::list<Key>::iterator lru;
    };
    struct DecoderSlot;
    class Worker;

    static Key keyFor(const ThumbnailRequest &request);
    static void deliver(std::vector<Waiter> waiters, const media::Result<ThumbnailImage> &result);
    void workerMain();
    media::Result<ThumbnailImage> produce(const ThumbnailRequest &request, Worker &worker, bool &fromDisk);
    media::Result<ThumbnailImage> decode(const ThumbnailRequest &request, Worker &worker);
    static media::Result<ThumbnailImage> render(Worker &worker, const media::PixelBuffer &frame, int maxDimension,
                                                int rotationDegrees);
    media::Result<std::shared_ptr<const media::RoutedMediaInfo>> route(const std::string &url,
                                                                      const media::RoutingPolicy &policy,
                                                                      const std::string &routeKey);
    void insertMemory(const Key &key, const ThumbnailImage &image); // mutex_ held

    const std::shared_ptr<media::BackendRouter> router_;
    const Config config_;

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::condition_variable idleCv_; ///< Notified when the last running job finishes.
    int running_ = 0;                ///< Jobs a worker took from queue_ and has not finished.
    bool stopping_ = false;
    std::deque<std::shared_ptr<Job>> queue_;
    std::map<Key, std::shared_ptr<Job>> jobs_; ///< Pending and running, for coalescing.
    std::map<Key, CacheEntry> memory_;
    std::list<Key> lru_;
    size_t memoryBytes_ = 0;
    struct RouteEntry {
        std::shared_ptr<const media::RoutedMediaInfo> routed;
        std::list<std::string>::iterator lru;
    };
    std::map<std::string, RouteEntry> routes_;
    std::list<std::string> routeLru_; ///< Front = most recently used.
    std::unique_ptr<DiskCacheBudget> disk_;
    std::list<std::unique_ptr<DecoderSlot>> idleDecoders_; ///< Front = most recently used.
    Stats stats_;
    std::vector<std::thread> threads_;
};

} // namespace ve::thumbs
