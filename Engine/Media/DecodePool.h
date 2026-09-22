// DecodePool: lookahead decoding into the FrameCache, plus the coalescing scrub path.
//
// Model
// - The playback controller describes what it will need soon with setTargets(): one
//   DecodeTarget per active clip (asset, track, the source time under the playhead, play
//   direction, priority). It calls setTargets whenever the playhead or the set of active clips
//   changes, typically once per displayed frame; the call is cheap (map updates and a condition
//   variable notify, no I/O).
// - Each target is served by a stream that owns one IVideoDecoder (opened through the
//   BackendRouter, off the caller's thread). A stream decodes frames in presentation order and
//   puts them into the FrameCache until its window is covered: [t, t + lookahead] forward,
//   [t - lookahead, t] backward (reverse play: the stream seeks back a window at a time and
//   decodes forward through it). Then it goes idle and wakes on the next setTargets that moves
//   t or changes the direction (frames were consumed), or on setLookahead().
// - A stream keeps a contiguous decoded range. A target inside the range (or at most
//   `seekAheadThreshold` past its end) continues decoding without a seek; anything else seeks
//   (a jump, a scrub release, a trim). If the frame under the playhead has vanished from the
//   cache (memory pressure, purge) the stream re-seeks once to restore it.
// - Targets are matched to streams by (asset, trackIndex, lane); `lane` distinguishes two
//   simultaneous uses of one asset (pass e.g. the clip id). Streams whose key is absent from
//   the latest setTargets are cancelled and their decoders destroyed on a worker thread.
//
// Threading model (std::thread + std::condition_variable, chosen over GCD so the thread count
// is a hard bound, workers can block in decoder calls without starving a shared GCD pool,
// shutdown can join deterministically, and tests can wait for a well-defined idle state)
// - Up to Config::maxThreads worker threads (default 4), started lazily, never more than the
//   number of streams (so min(4, active clips)). Workers take one step at a time from the
//   runnable stream with the highest priority (ties: least recently served): a step is one
//   open, one seek, or one next(). Between steps a worker re-reads the stream's target, so a
//   re-target takes effect after at most the one frame decode already in flight. A stream is
//   stepped by one worker at a time (decoders are not thread-safe, but may migrate between
//   threads between calls, per Interfaces.h).
// - One scrub thread, started on the first requestFrame(), with its own decoders (at most
//   Config::maxScrubDecoders, LRU) so scrubbing never disturbs the sequential streams.
// - No busy waiting: idle threads block on condition variables.
// - Callbacks from requestFrame() run on the scrub thread, never inside requestFrame() and
//   never with a pool lock held (they may call back into the pool). Each callback is invoked
//   exactly once: with the frame, with an error, or with MediaErrorCode::Cancelled when a
//   newer request for the same asset superseded it or the pool is being destroyed.
// - The destructor cancels pending scrub requests (invoking their callbacks), stops and joins
//   every thread and destroys every decoder before returning. Frames already in the cache
//   stay there.
// - All public methods are thread-safe.
#pragma once

#include "../Model/Ids.h"
#include "BackendRouter.h"
#include "FrameCache.h"

#include <chrono>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ve::media {

enum class DecodeDirection { Forward, Backward };

struct DecodeTarget {
    AssetId asset;
    /// Media path; may be empty if registerAsset() provided it. A different path than the one
    /// registered re-routes the asset and reopens its streams (relink).
    std::string url;
    int trackIndex = -1;                ///< TrackInfo::index of the routed info; -1 = first video/still.
    CMTime sourceTime = kCMTimeZero;    ///< Source time under the playhead.
    DecodeDirection direction = DecodeDirection::Forward;
    int priority = 0;                   ///< Higher is served first (e.g. the top visible layer).
    uint64_t lane = 0;                  ///< Distinguishes simultaneous targets on one asset.
};

/// A frame delivered by requestFrame().
struct ScrubFrame {
    PixelBuffer image;
    CMTime pts = kCMTimeInvalid;
    CMTime duration = kCMTimeInvalid;
    int64_t frameIndex = 0; ///< FrameCache slot.
    bool fromCache = false;
};
using ScrubCallback = std::function<void(Result<ScrubFrame>)>;

class DecodePool {
  public:
    struct Config {
        CMTime lookahead = CMTimeMake(1, 1);
        /// A target at most this far past the decoded range is decoded through instead of
        /// seeking (the frames in between are cheap compared to a seek into a long GOP).
        CMTime seekAheadThreshold = CMTimeMake(1, 2);
        int maxThreads = 4;
        int maxScrubDecoders = 4;
        /// Options for every decoder the pool opens (pixelFormat, allowHardware...).
        DecodeOptions decodeOptions;
    };

    struct StreamStats {
        AssetId asset;
        int trackIndex = -1;
        uint64_t lane = 0;
        std::string backend;
        bool hardware = false;
        bool idle = false;
        bool failed = false;
        CMTime target = kCMTimeInvalid;
        CMTime rangeStart = kCMTimeInvalid; ///< Decoded contiguous range.
        CMTime rangeEnd = kCMTimeInvalid;
        uint64_t framesDecoded = 0;
        uint64_t seeks = 0;
        std::optional<MediaError> error;
    };

    struct Stats {
        std::vector<StreamStats> streams;
        int workerThreads = 0;
        uint64_t scrubRequests = 0;
        uint64_t scrubServiced = 0;  ///< Callbacks invoked with a frame.
        uint64_t scrubCancelled = 0; ///< Callbacks invoked with Cancelled.
        uint64_t scrubFailed = 0;    ///< Callbacks invoked with another error.
    };

    DecodePool(std::shared_ptr<BackendRouter> router, std::shared_ptr<FrameCache> cache);
    DecodePool(std::shared_ptr<BackendRouter> router, std::shared_ptr<FrameCache> cache, Config config);
    ~DecodePool();
    DecodePool(const DecodePool &) = delete;
    DecodePool &operator=(const DecodePool &) = delete;

    /// Associates `asset` with a media path and optionally its routing (as computed at import,
    /// which saves a probe). Replacing the path of a known asset reopens its streams.
    void registerAsset(AssetId asset, std::string url, std::optional<RoutedMediaInfo> routed = std::nullopt);
    /// Forgets the routing and decoders of `asset` (after relink or a file change); streams
    /// reopen on their next step. Does not purge the cache: call FrameCache::purge as well.
    void invalidate(AssetId asset);

    /// Replaces the complete set of lookahead targets (see header comment).
    void setTargets(std::vector<DecodeTarget> targets);
    void setLookahead(CMTime lookahead);
    CMTime lookahead() const;

    /// Scrub path: decode the frame of `asset` at `time` as soon as possible (cache first).
    /// Only the latest pending request per asset is serviced; a request replaced before it
    /// started gets its callback invoked with Cancelled. The asset's path must be known from
    /// registerAsset() or a target (else the callback receives InvalidArgument). Uses the
    /// asset's first video/still track.
    void requestFrame(AssetId asset, CMTime time, ScrubCallback callback);

    /// Blocks until every stream is idle (window covered, end of stream or failed), removed
    /// streams' decoders are destroyed and no scrub request is pending or running, or until
    /// `timeout`. Returns whether idle was reached.
    /// For tests, export pre-roll and diagnostics.
    bool waitUntilIdle(std::chrono::milliseconds timeout);

    Stats stats() const;

  private:
    struct AssetSlot;
    struct Stream;
    struct StreamKey {
        AssetId asset;
        int trackIndex = -1;
        uint64_t lane = 0;
        friend auto operator<=>(const StreamKey &, const StreamKey &) = default;
    };
    struct ScrubRequest {
        CMTime time = kCMTimeInvalid;
        ScrubCallback callback;
        uint64_t sequence = 0;
    };
    struct ScrubDecoder;
    enum class StepResult { Progress, Settled };

    std::shared_ptr<AssetSlot> slotFor(AssetId asset, const std::string &url); // mutex_ held
    void ensureWorkers();                                                     // mutex_ held
    void workerMain();
    void scrubMain();
    Stream *pickStream(); // mutex_ held
    StepResult step(Stream &stream, const DecodeTarget &target, const std::shared_ptr<AssetSlot> &slot, CMTime window,
                    bool reopen);
    void publish(Stream &stream); // mutex_ held
    Result<ScrubFrame> serviceScrub(AssetId asset, const std::shared_ptr<AssetSlot> &slot, CMTime time);

    const std::shared_ptr<BackendRouter> router_;
    const std::shared_ptr<FrameCache> cache_;
    const Config config_;

    mutable std::mutex mutex_;
    std::condition_variable workCv_;     ///< Workers: a stream became runnable, or stop.
    std::condition_variable progressCv_; ///< waitUntilIdle: a step or scrub request finished.
    std::condition_variable scrubCv_;    ///< Scrub thread: a request arrived, or stop.
    bool stopping_ = false;
    CMTime lookahead_;
    uint64_t tick_ = 0;
    std::map<AssetId, std::shared_ptr<AssetSlot>> assets_;
    std::map<StreamKey, std::shared_ptr<Stream>> streams_;
    std::vector<std::shared_ptr<Stream>> retired_; ///< Destroyed by a worker, off the caller's thread.
    int retiring_ = 0;                             ///< Workers currently destroying retired streams.
    std::vector<std::thread> workers_;

    // Scrub state (mutex_).
    std::map<AssetId, ScrubRequest> scrubPending_;
    std::vector<ScrubCallback> scrubToCancel_;
    uint64_t scrubSequence_ = 0;
    bool scrubBusy_ = false;
    std::thread scrubThread_;
    uint64_t scrubRequests_ = 0;
    uint64_t scrubServiced_ = 0;
    uint64_t scrubCancelled_ = 0;
    uint64_t scrubFailed_ = 0;
    /// Scrub decoders: touched only by the scrub thread (and the destructor after joining it).
    std::map<AssetId, std::unique_ptr<ScrubDecoder>> scrubDecoders_;
    uint64_t scrubUseCounter_ = 0;
};

} // namespace ve::media
