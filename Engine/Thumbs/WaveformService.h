// WaveformService: per-asset audio peak arrays for timeline waveforms.
//
// Peaks are min/max pairs per bucket at a fixed resolution (Config::bucketsPerSecond, default
// 100 buckets per second, i.e. 480 samples at the 48 kHz analysis rate), computed from the
// asset's first audio track (or a chosen one) decoded through the BackendRouter's
// IAudioDecoder, with vDSP. They are kept per channel (up to 8) and as a mono mix (the channel
// average, so it stays within [-1, 1]). Bucket i covers [i, i + 1) / bucketsPerSecond seconds;
// the last bucket may be partial.
//
// Caching: in memory per (asset, track), valid only while the source file keeps the size and
// modification time it had when the peaks were computed (a replaced file is recomputed), and on
// disk under Config::diskCacheDirectory as "<hash>.vewf" (bounded by Config::diskBudgetBytes,
// least recently used files deleted), a little-endian binary file:
//   magic "VEWF", u32 version, u64 source size, i64 source mtime (ns), f64 sample rate,
//   u32 bucketsPerSecond, u32 channels, u64 bucketCount, then bucketCount x (min f32, max f32)
//   for the mono mix followed by the same for each channel.
// The hash covers the path, file size, mtime, track, resolution and format version, and the
// header is re-validated on load, so an edited source is recomputed.
//
// Threading: public methods are thread-safe and non-blocking (request() and cached() stat the
// source file). Computation runs on Config::threads worker threads (std::thread, each job in its
// own autorelease pool). Requests for the same (asset, track) share one
// computation. Progress and completion callbacks are dispatch_async'ed onto the queue passed
// with the request (never inline); every completion runs exactly once, with the peaks, an
// error, or MediaErrorCode::Cancelled (cancel(), or destruction before completion). A
// computation whose requests were all cancelled stops at its next chunk (~1/3 s of audio).
// The destructor cancels everything and joins its threads.
#pragma once

#include "../Media/BackendRouter.h"
#include "../Model/Ids.h"

#include <dispatch/dispatch.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace ve::thumbs {

class DiskCacheBudget; // CacheKey.h

struct PeakBucket {
    float min = 0;
    float max = 0;
    bool operator==(const PeakBucket &) const = default;
};

struct WaveformPeaks {
    static constexpr uint32_t kFormatVersion = 1;

    double sampleRate = 0;        ///< Analysis rate.
    uint32_t bucketsPerSecond = 0;
    uint32_t channels = 0;
    std::vector<PeakBucket> mono; ///< bucketCount() entries.
    std::vector<std::vector<PeakBucket>> perChannel; ///< channels x bucketCount().

    size_t bucketCount() const { return mono.size(); }
    /// Samples (at sampleRate) per bucket.
    int samplesPerBucket() const;
    /// Bucket containing time `seconds` (clamped to the valid range; 0 when empty).
    size_t bucketAt(double seconds) const;
    bool operator==(const WaveformPeaks &) const = default;
};

/// Identity of the source a peak file was computed from (see CacheKey.h FileIdentity).
struct WaveformSource {
    uint64_t size = 0;
    int64_t modifiedNanoseconds = 0;
};

/// Serialises `peaks` in the .vewf format (see header comment).
media::Status writeWaveformFile(const std::string &path, const WaveformPeaks &peaks, const WaveformSource &source);
/// Reads a .vewf file. CorruptData for a malformed or truncated file, UnsupportedFormat for
/// another version, InvalidState if `expected` is given and the file was made from a
/// different source.
media::Result<WaveformPeaks> readWaveformFile(const std::string &path, const WaveformSource *expected = nullptr);

struct WaveformRequest {
    AssetId asset;
    std::string url;
    int trackIndex = -1; ///< Audio track of the routed info; -1 = first.
};

using WaveformResult = media::Result<std::shared_ptr<const WaveformPeaks>>;
using WaveformCallback = std::function<void(WaveformResult)>;
/// Fraction done in [0, 1]; called at most every ~5 % of progress.
using WaveformProgress = std::function<void(double)>;

class WaveformService {
  public:
    struct Config {
        /// Directory for .vewf files; created on demand. Empty disables the disk cache.
        std::string diskCacheDirectory;
        /// Disk cache bound (0 = unbounded).
        uint64_t diskBudgetBytes = uint64_t(256) << 20;
        uint32_t bucketsPerSecond = 100;
        /// Analysis sample rate; must be a multiple of bucketsPerSecond.
        double sampleRate = 48000;
        int threads = 1;
        media::RoutingPolicy routing;
    };

    using RequestId = uint64_t;

    struct Stats {
        uint64_t requests = 0;
        uint64_t memoryHits = 0;
        uint64_t diskHits = 0;
        uint64_t computed = 0;
        uint64_t cancelled = 0;
        uint64_t failures = 0;
        uint64_t diskWriteFailures = 0;
    };

    WaveformService(std::shared_ptr<media::BackendRouter> router, Config config);
    ~WaveformService();
    WaveformService(const WaveformService &) = delete;
    WaveformService &operator=(const WaveformService &) = delete;

    /// Starts (or joins) the computation of the peaks of `request`. Returns an id for cancel().
    /// Invalid arguments (empty path, null queue, a sample rate that is not a multiple of the
    /// bucket rate) complete with InvalidArgument.
    RequestId request(const WaveformRequest &request, dispatch_queue_t queue, WaveformCallback completion,
                      WaveformProgress progress = {});
    /// Cancels one request: its completion receives Cancelled (asynchronously) unless it
    /// already completed. Returns false if the id is unknown or already finished.
    bool cancel(RequestId id);

    /// Peaks already in memory for the asset's file as it is now, or nullptr.
    std::shared_ptr<const WaveformPeaks> cached(AssetId asset, int trackIndex = -1) const;
    /// Forgets the in-memory peaks of `asset`.
    void purge(AssetId asset);

    Stats stats() const;

    /// Disk cache file name for a request (exposed for tests and cache management).
    std::string diskFileName(const WaveformRequest &request) const;

  private:
    struct Key {
        AssetId asset;
        int trackIndex = -1;
        friend auto operator<=>(const Key &, const Key &) = default;
    };
    struct Listener {
        RequestId id = 0;
        dispatch_queue_t queue;
        WaveformCallback completion;
        WaveformProgress progress;
    };
    struct Job {
        Key key;
        WaveformRequest request;
        std::vector<Listener> listeners;
        std::atomic<bool> cancelled{false};
        bool started = false;
    };

    void workerMain();
    WaveformResult produce(Job &job, bool &fromDisk);
    WaveformResult compute(Job &job);
    void reportProgress(Job &job, double fraction);
    static void complete(std::vector<Listener> listeners, const WaveformResult &result);

    const std::shared_ptr<media::BackendRouter> router_;
    const Config config_;

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    bool stopping_ = false;
    RequestId nextId_ = 1;
    std::deque<std::shared_ptr<Job>> queue_;
    std::map<Key, std::shared_ptr<Job>> jobs_; ///< Pending and running.
    struct MemoryEntry {
        std::shared_ptr<const WaveformPeaks> peaks;
        std::string url;
        uint64_t fileSize = 0;
        int64_t fileModified = 0;
    };
    std::map<Key, MemoryEntry> memory_;
    std::unique_ptr<DiskCacheBudget> disk_;
    Stats stats_;
    std::vector<std::thread> threads_;
};

} // namespace ve::thumbs
