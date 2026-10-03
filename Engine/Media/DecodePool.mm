#include "DecodePool.h"

#include "../Model/TimeUtil.h"
#include "LastFrame.h"

#include <os/log.h>

#include <algorithm>
#include <cmath>

namespace ve::media {

namespace {

os_log_t poolLog() {
    static os_log_t log = os_log_create("ve.media.decodepool", "decode");
    return log;
}

MediaError cancelledError() {
    return makeError(MediaErrorCode::Cancelled, "superseded by a newer request or pool shutdown");
}

/// End of a decoded frame: pts + duration, falling back to the nominal frame duration, and to
/// +infinity (a still) when neither is known.
CMTime frameEnd(const VideoFrame &f, CMTime frameDuration) {
    if (CMTIME_IS_POSITIVE_INFINITY(f.duration)) {
        return kCMTimePositiveInfinity;
    }
    if (isPositive(f.duration)) {
        return f.pts + f.duration;
    }
    if (isPositive(frameDuration)) {
        return f.pts + frameDuration;
    }
    return kCMTimePositiveInfinity;
}

CMTime clampToZero(CMTime t) {
    return isNumeric(t) ? maxTime(t, kCMTimeZero) : kCMTimeZero;
}

/// The generated key a target's pictures are put under (empty for decoded media).
GeneratedKey generatedKeyOf(const DecodeTarget &target) {
    return target.generated ? target.generated->key() : GeneratedKey{};
}

} // namespace

// MARK: - Internal types

struct DecodePool::AssetSlot {
    AssetSlot(std::string path, FrameCache::Epoch mediaEpoch) : url(std::move(path)), epoch(mediaEpoch) {}
    AssetSlot(std::string path, FrameCache::Epoch mediaEpoch, RoutedMediaInfo info)
        : url(std::move(path)), epoch(mediaEpoch), resolved(true),
          routed(std::make_shared<const RoutedMediaInfo>(std::move(info))) {}

    const std::string url; ///< Immutable: readable without `mutex`.
    const FrameCache::Epoch epoch; ///< Media epoch the slot belongs to (frames are put under it).
    /// The slot no longer describes its asset (relinked, invalidated, or its epoch ended): its
    /// frames are not published any more. Guarded by DecodePool::mutex_.
    bool retired = false;

    /// Routes the asset (blocking; concurrent callers wait for the first). A definitive probe
    /// error is remembered; a transient one (isTransient: a load timeout) is not, so the next
    /// call probes again.
    Result<std::shared_ptr<const RoutedMediaInfo>> resolve(const BackendRouter &router) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!resolved) {
            if (url.empty()) {
                return makeError(MediaErrorCode::InvalidArgument, "no media path registered for the asset");
            }
            auto r = router.probe(url);
            if (!r.ok()) {
                if (isTransient(r.error().code)) {
                    return std::move(r).error();
                }
                error = std::move(r).error();
            } else {
                routed = std::make_shared<const RoutedMediaInfo>(std::move(r).value());
            }
            resolved = true;
        }
        if (routed) {
            return routed;
        }
        return *error;
    }

  private:
    std::mutex mutex; ///< Held while probing.
    bool resolved = false;
    std::shared_ptr<const RoutedMediaInfo> routed;
    std::optional<MediaError> error;
};

struct DecodePool::Stream {
    StreamKey key;

    // Guarded by DecodePool::mutex_.
    std::shared_ptr<AssetSlot> slot;
    DecodeTarget target;
    uint64_t generation = 0; ///< Bumped when the target moves; a settled step at an old generation is re-run.
    bool busy = false;       ///< A worker is stepping this stream (it owns the fields below).
    bool idle = false;       ///< Settled at `generation`: nothing to do until the target moves.
    bool removed = false;
    bool failed = false;          ///< Open failed; stays idle until reopened (or, if transient, retargeted).
    bool failedTransient = false; ///< The failure was transient (isTransient).
    bool reopen = false;          ///< Drop the decoder before the next step.
    /// refresh() asked to forget `repairedAt` (re-arm the repair of an evicted playhead frame). The
    /// worker owns `repairedAt` and consumes this flag at the start of its next step, as it does
    /// `reopen` (refresh() writing `repairedAt` itself raced the worker: review B3).
    bool rearmRepair = false;
    /// Waiting for a scrub request of the target's continueScrubLane to hand its decoder over
    /// (StepResult::AwaitScrub): not stepped until the request ends or the target moves.
    bool awaitingScrub = false;
    /// The step in flight opens the decoder (set with `busy`): suspendTargets() leaves it alone (an
    /// interrupted open is thrown away, and FFmpeg decodes its first frame inside open()).
    bool opening = false;
    uint64_t lastServed = 0;
    StreamStats published;
    /// Shared with the decoder (DecodeOptions::interrupt): setTargets() requests it when the
    /// work in flight became useless; the worker clears it before every step. It travels with the
    /// decoder: a hand-off gives the stream the scrub decoder's (written by the stream's worker
    /// under DecodePool::mutex_, read under it or by that worker).
    std::shared_ptr<DecodeInterrupt> interrupt = std::make_shared<DecodeInterrupt>();

    // Owned by the worker that set `busy` (no lock needed while busy).
    std::unique_ptr<IVideoDecoder> decoder;
    /// The generated key of the source `decoder` renders (empty for decoded media): its pictures are put
    /// under this key, whatever the target says meanwhile.
    GeneratedKey openedKey;
    CMTime frameDuration = kCMTimeInvalid;
    std::string backend;
    bool hardware = false;
    bool rangeValid = false; ///< [rangeStart, rangeEnd) is decoded into the cache.
    CMTime rangeStart = kCMTimeZero;
    CMTime rangeEnd = kCMTimeZero;
    bool continues = false;  ///< The decoder's next frame starts at rangeEnd.
    bool eof = false;        ///< rangeEnd is the end of the stream.
    CMTime videoEnd = kCMTimeInvalid;  ///< End of the last frame, once the end was reached.
    CMTime trackEnd = kCMTimeInvalid;  ///< The prober's end of the track (startTime + duration).
    /// The last frame decoded since the last seek (not while extending backwards): re-put with an
    /// infinite duration when the end of the stream follows it (the hold, see the header). One
    /// buffer per stream, normally the one the cache holds as well.
    std::optional<VideoFrame> lastDecoded;
    /// A seek landed at or after the end: seeking back in growing steps (tailStep) from
    /// tailProbe to find the last frame, then decoding forward to the end.
    bool findingEnd = false;
    CMTime tailProbe = kCMTimeInvalid;
    CMTime tailStep = kCMTimeInvalid;
    bool firstAfterSeek = false;
    CMTime seekedTo = kCMTimeInvalid;  ///< Target of the last seek (frames after it cover back to it).
    CMTime repairedAt = kCMTimeInvalid; ///< Target at which a lost frame was last re-decoded.
    bool extending = false;  ///< Backward: decoding [extendStart, extendUntil) below the range.
    CMTime extendStart = kCMTimeZero;
    CMTime extendUntil = kCMTimeZero;
    bool openFailed = false;
    size_t frameBytes = 0;
    CMTime window = kCMTimeInvalid;
    uint64_t framesDecoded = 0;
    uint64_t seeks = 0;
    uint64_t interrupts = 0;
    uint64_t handoffs = 0;
    std::optional<MediaError> error;
};

struct DecodePool::ScrubDecoder {
    std::unique_ptr<IVideoDecoder> decoder;
    std::shared_ptr<AssetSlot> slot;
    GeneratedKey generated; ///< The source it renders (empty: it decodes the slot's media).
    std::shared_ptr<DecodeInterrupt> interrupt;
    std::string backend; ///< The backend that opened it.
    uint64_t lastUse = 0;
    /// The last request decoded `delivered` (sought to `requestTime`, which `delivered` covers from
    /// `coverFrom` to `end`) and nothing moved the decoder since: its next frame follows `delivered`,
    /// as a stream's would after seeking to requestTime and decoding one frame (the hand-off).
    /// `delivered` keeps no image (the cache has it; holding it here would keep a picture alive
    /// outside the cache's budget).
    bool positioned = false;
    CMTime requestTime = kCMTimeInvalid;
    CMTime coverFrom = kCMTimeInvalid;
    CMTime end = kCMTimeInvalid;
    VideoFrame delivered;
};

// MARK: - Lifetime

DecodePool::DecodePool(std::shared_ptr<BackendRouter> router, std::shared_ptr<FrameCache> cache)
    : DecodePool(std::move(router), std::move(cache), Config{}) {}

DecodePool::DecodePool(std::shared_ptr<BackendRouter> router, std::shared_ptr<FrameCache> cache, Config config)
    : router_(std::move(router)), cache_(std::move(cache)), config_([&] {
          Config c = config;
          c.maxThreads = std::max(1, c.maxThreads);
          c.maxScrubDecoders = std::max(1, c.maxScrubDecoders);
          c.minWindowFrames = std::max(1, c.minWindowFrames);
          if (!(c.budgetFraction > 0 && c.budgetFraction <= 1)) {
              c.budgetFraction = 0.75;
          }
          if (!isPositive(c.lookahead)) {
              c.lookahead = CMTimeMake(1, 1);
          }
          if (!isNumeric(c.seekAheadThreshold) || c.seekAheadThreshold < kCMTimeZero) {
              c.seekAheadThreshold = kCMTimeZero;
          }
          c.decodeOptions.interrupt.reset(); // Per decoder, set by the pool.
          return c;
      }()),
      lookahead_(config_.lookahead) {
    epoch_ = cache_->epoch();
}

DecodePool::~DecodePool() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        for (auto &[key, stream] : streams_) {
            stream->interrupt->request(); // Abandon long decodes: shutdown must not wait a GOP.
        }
        if (scrubInterrupt_) {
            scrubInterrupt_->request();
        }
    }
    workCv_.notify_all();
    scrubCv_.notify_all();
    progressCv_.notify_all();
    for (std::thread &t : workers_) {
        t.join();
    }
    if (scrubThread_.joinable()) {
        scrubThread_.join();
    }
    // Every thread is gone; nothing else can touch the state below.
    streams_.clear();
    retired_.clear();
    scrubDecoders_.clear();
    cache_->setFocus(focusClient_, {});
}

// MARK: - Assets

void DecodePool::retire(AssetId asset, const std::shared_ptr<AssetSlot> &slot) {
    slot->retired = true;
    if (scrubThread_.joinable()) {
        scrubCleanupPending_ = true; // the scrub thread may hold a decoder of it
    }
    if (scrubBusy_ && scrubInterrupt_ && scrubInFlight_.asset == asset) {
        scrubInterrupt_->request(); // its result would be discarded anyway
    }
}

std::shared_ptr<DecodePool::AssetSlot> DecodePool::slotFor(AssetId asset, const std::string &url) {
    auto it = assets_.find(asset);
    if (it != assets_.end() && (url.empty() || url == it->second->url)) {
        return it->second;
    }
    auto slot = std::make_shared<AssetSlot>(url, epoch_);
    const bool relinked = it != assets_.end();
    if (relinked) {
        retire(asset, it->second);
    }
    assets_[asset] = slot;
    if (relinked) {
        for (auto &[key, stream] : streams_) {
            if (key.asset == asset) {
                stream->slot = slot;
                stream->reopen = true;
                stream->failed = false;
                stream->idle = false;
                stream->interrupt->request();
                ++stream->generation;
            }
        }
    }
    return slot;
}

void DecodePool::registerAsset(AssetId asset, std::string url, std::optional<RoutedMediaInfo> routed) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = assets_.find(asset);
        const bool sameUrl = it != assets_.end() && it->second->url == url;
        if (sameUrl && !routed) {
            return;
        }
        auto slot = routed ? std::make_shared<AssetSlot>(url, epoch_, std::move(*routed))
                           : std::make_shared<AssetSlot>(url, epoch_);
        if (it != assets_.end() && !sameUrl) {
            retire(asset, it->second); // another file now: the old one's frames must not be published
        }
        assets_[asset] = slot;
        for (auto &[key, stream] : streams_) {
            if (key.asset == asset) {
                stream->slot = slot;
                if (!sameUrl || stream->failed) {
                    // A new path, or new routing for a stream that could not open: reopen.
                    stream->reopen = true;
                    stream->failed = false;
                    stream->idle = false;
                    stream->interrupt->request();
                    ++stream->generation;
                }
            }
        }
    }
    workCv_.notify_all();
    scrubCv_.notify_all();
}

void DecodePool::invalidate(AssetId asset) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = assets_.find(asset);
        if (it == assets_.end()) {
            return;
        }
        auto slot = std::make_shared<AssetSlot>(it->second->url, epoch_);
        retire(asset, it->second);
        it->second = slot;
        for (auto &[key, stream] : streams_) {
            if (key.asset == asset) {
                stream->slot = slot;
                stream->reopen = true;
                stream->failed = false;
                stream->idle = false;
                stream->interrupt->request();
                ++stream->generation;
            }
        }
    }
    workCv_.notify_all();
    scrubCv_.notify_all();
}

void DecodePool::beginEpoch(FrameCache::Epoch epoch) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) {
            return;
        }
        for (auto &[asset, slot] : assets_) {
            retire(asset, slot);
        }
        assets_.clear();
        epoch_ = epoch;
        for (auto &[key, stream] : streams_) {
            stream->removed = true;
            stream->interrupt->request();
            retire(key.asset, stream->slot); // normally in assets_ too; retiring twice is harmless
            if (!stream->busy) {
                retired_.push_back(stream);
            }
        }
        streams_.clear();
        for (auto &[key, request] : scrubPending_) {
            scrubToCancel_.push_back(std::move(request.callback));
        }
        scrubPending_.clear();
        if (scrubBusy_ && scrubInterrupt_) {
            scrubInterrupt_->request();
        }
        if (scrubThread_.joinable()) {
            scrubCleanupPending_ = true;
        }
        updateFocus();
    }
    workCv_.notify_all();
    scrubCv_.notify_all();
}

// MARK: - Targets

bool DecodePool::makesWorkInFlightUseless(const Stream &s, const DecodeTarget &next) const {
    if (next.direction != s.target.direction) {
        return true;
    }
    const StreamStats &p = s.published;
    if (!isNumeric(p.rangeStart) || !isNumeric(p.rangeEnd)) {
        return false; // Opening, or nothing decoded yet: the work in flight is the open itself.
    }
    const CMTime t = clampToZero(next.sourceTime);
    if (next.direction == DecodeDirection::Forward) {
        return t < p.rangeStart || t > p.rangeEnd + config_.seekAheadThreshold;
    }
    const CMTime window = isNumeric(p.window) ? p.window : lookahead_;
    return t < p.rangeStart - window || t > p.rangeEnd + config_.seekAheadThreshold;
}

void DecodePool::updateFocus() {
    std::vector<FrameCache::Focus> focus;
    focus.reserve(streams_.size());
    for (const auto &[key, stream] : streams_) {
        focus.push_back(FrameCache::Focus{key.asset, clampToZero(stream->target.sourceTime),
                                          stream->target.direction == DecodeDirection::Forward,
                                          generatedKeyOf(stream->target)});
    }
    cache_->setFocus(focusClient_, std::move(focus));
}

void DecodePool::setTargets(std::vector<DecodeTarget> targets) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) {
            return;
        }
        suspended_ = false;
        std::map<StreamKey, std::shared_ptr<Stream>> next;
        for (DecodeTarget &t : targets) {
            if (!t.asset.isValid()) {
                continue;
            }
            t.sourceTime = clampToZero(t.sourceTime);
            auto slot = slotFor(t.asset, t.url);
            const StreamKey key{t.asset, t.trackIndex, t.lane};
            if (next.count(key) != 0) {
                continue; // Duplicate key: the first target wins.
            }
            std::shared_ptr<Stream> stream;
            auto it = streams_.find(key);
            if (it != streams_.end()) {
                stream = it->second;
                if (generatedKeyOf(t) != generatedKeyOf(stream->target)) {
                    // Another generated picture (the title's content changed): like a relink, the
                    // stream reopens on the new source; what the old one renders is published under
                    // its own key.
                    stream->reopen = true;
                    stream->failed = false;
                    stream->idle = false;
                    stream->interrupt->request();
                    ++stream->generation;
                }
                const bool moved =
                    t.sourceTime != stream->target.sourceTime || t.direction != stream->target.direction;
                if (moved && stream->busy && !stream->failed && makesWorkInFlightUseless(*stream, t)) {
                    stream->interrupt->request();
                }
                stream->target = std::move(t);
                if (moved) {
                    stream->awaitingScrub = false; // the step re-decides for the new target
                }
                // Permanent failures wait for registerAsset()/invalidate(); transient ones retry.
                if (moved && (!stream->failed || stream->failedTransient)) {
                    ++stream->generation;
                    stream->idle = false;
                    stream->failed = false;
                }
            } else {
                stream = std::make_shared<Stream>();
                stream->key = key;
                stream->slot = slot;
                stream->target = std::move(t);
                stream->published.asset = key.asset;
                stream->published.trackIndex = key.trackIndex;
                stream->published.lane = key.lane;
            }
            next.emplace(key, std::move(stream));
        }
        for (auto &[key, stream] : streams_) {
            if (next.count(key) == 0) {
                stream->removed = true;
                stream->interrupt->request();
                if (!stream->busy) {
                    retired_.push_back(stream);
                }
            }
        }
        streams_.swap(next);
        updateFocus();
        ensureWorkers();
    }
    workCv_.notify_all();
}

void DecodePool::suspendTargets() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ || suspended_) {
        return;
    }
    suspended_ = true;
    for (auto &[key, stream] : streams_) {
        // A decode in flight stops after the frame it is on; an open finishes (it is not wasted, and the
        // stream keeps its decoder for when the targets come back).
        if (stream->busy && !stream->opening) {
            stream->interrupt->request();
        }
    }
}

void DecodePool::setLookahead(CMTime lookahead) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!isPositive(lookahead) || lookahead == lookahead_) {
            return;
        }
        lookahead_ = lookahead;
        for (auto &[key, stream] : streams_) {
            if (!stream->failed) {
                ++stream->generation;
                stream->idle = false;
            }
        }
    }
    workCv_.notify_all();
}

CMTime DecodePool::lookahead() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return lookahead_;
}

DecodeFormat DecodePool::decodeFormat() const {
    return decodeFormatOf(config_.decodeOptions); // config_ never changes after construction
}

FrameKey DecodePool::frameKey(AssetId asset, GeneratedKey generated) const {
    return FrameKey{asset, decodeFormat(), generated};
}

void DecodePool::ensureWorkers() {
    const size_t wanted = std::min(static_cast<size_t>(config_.maxThreads), streams_.size());
    while (workers_.size() < wanted) {
        workers_.emplace_back([this] { workerMain(); });
    }
}

// MARK: - Workers

DecodePool::Stream *DecodePool::pickStream() {
    if (suspended_) {
        return nullptr; // held until the next setTargets()
    }
    Stream *best = nullptr;
    for (auto &[key, stream] : streams_) {
        Stream *s = stream.get();
        if (s->busy || s->idle || s->awaitingScrub) {
            continue;
        }
        if (best == nullptr || s->target.priority > best->target.priority ||
            (s->target.priority == best->target.priority && s->lastServed < best->lastServed)) {
            best = s;
        }
    }
    return best;
}

void DecodePool::publish(Stream &s) {
    StreamStats &p = s.published;
    p.backend = s.backend;
    p.hardware = s.hardware;
    p.idle = s.idle;
    p.failed = s.failed;
    p.target = s.target.sourceTime;
    p.rangeStart = s.rangeValid ? s.rangeStart : kCMTimeInvalid;
    p.rangeEnd = s.rangeValid ? s.rangeEnd : kCMTimeInvalid;
    p.window = s.window;
    p.frameBytes = s.frameBytes;
    p.eof = s.eof;
    p.videoEnd = s.videoEnd;
    p.framesDecoded = s.framesDecoded;
    p.seeks = s.seeks;
    p.interrupts = s.interrupts;
    p.handoffs = s.handoffs;
    p.error = s.error;
}

void DecodePool::workerMain() {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        if (!retired_.empty()) {
            std::vector<std::shared_ptr<Stream>> dead;
            dead.swap(retired_);
            ++retiring_;
            lock.unlock();
            dead.clear(); // Destroys decoders outside the lock.
            lock.lock();
            --retiring_;
            progressCv_.notify_all();
            continue;
        }
        if (stopping_) {
            return;
        }
        Stream *s = pickStream();
        if (s == nullptr) {
            workCv_.wait(lock);
            continue;
        }
        std::shared_ptr<Stream> keep = streams_.at(s->key);
        ++stepsInFlight_;
        s->busy = true;
        s->lastServed = ++tick_;
        s->interrupt->clear(); // Any request so far concerned the target read below or earlier.
        const DecodeTarget target = s->target;
        const uint64_t generation = s->generation;
        const std::shared_ptr<AssetSlot> slot = s->slot;
        const CMTime window = lookahead_;
        const size_t streamCount = std::max<size_t>(1, streams_.size());
        const bool reopen = std::exchange(s->reopen, false);
        const bool rearmRepair = std::exchange(s->rearmRepair, false);
        s->opening = reopen || !s->decoder; // not busy until now: the decoder is read under the lock
        lock.unlock();
        if (rearmRepair) {
            s->repairedAt = kCMTimeInvalid; // busy: the worker owns it now
        }

        StepResult result = StepResult::Progress;
        @autoreleasepool { // std::thread has no pool; decoders and probers autorelease.
            result = step(*s, target, slot, window, streamCount, reopen);
        }

        lock.lock();
        --stepsInFlight_;
        s->busy = false;
        if (s->reopen) {
            // registerAsset()/invalidate() during the step: whatever this step concluded
            // (typically a failure of the old path) is stale; the next step reopens.
            s->failed = false;
            s->idle = false;
        } else {
            s->failed = s->openFailed;
            s->failedTransient = s->openFailed && s->error && isTransient(s->error->code);
            if (result == StepResult::Settled && s->generation == generation) {
                s->idle = true;
            }
            // Waits for the hand-off only while the request is still to come (it may have ended
            // since the step looked: then the stream steps again at once and takes it over).
            if (result == StepResult::AwaitScrub && s->generation == generation && !s->removed &&
                scrubWillPositionLocked(s->target, clampToZero(s->target.sourceTime))) {
                s->awaitingScrub = true;
            }
        }
        publish(*s);
        if (s->removed) {
            retired_.push_back(std::move(keep));
        }
        progressCv_.notify_all();
    }
}

bool DecodePool::publishStreamFrame(const Stream &s, const std::shared_ptr<AssetSlot> &slot, const VideoFrame &f,
                                    CMTime frameDuration, CMTime coverFrom) {
    // Checked and put under mutex_, so a removal, relink, invalidate() or beginEpoch() that
    // returned before cannot be overtaken by this put.
    std::lock_guard<std::mutex> lock(mutex_);
    if (s.removed || slot->retired || slot->epoch != epoch_) {
        return false;
    }
    return cache_->put(slot->epoch, frameKey(s.key.asset, s.openedKey), f, frameDuration, coverFrom);
}

CMTime DecodePool::effectiveWindow(const Stream &s, CMTime lookahead, size_t streamCount) const {
    if (s.frameBytes == 0 || !isPositive(s.frameDuration)) {
        return lookahead; // Size unknown until the first frame (or a still): nothing to limit yet.
    }
    const double share =
        static_cast<double>(cache_->budget()) * config_.budgetFraction / static_cast<double>(streamCount);
    const auto frames = std::max<int64_t>(config_.minWindowFrames,
                                          static_cast<int64_t>(std::floor(share / static_cast<double>(s.frameBytes))));
    const CMTime byBudget = timeForFrame(frames, s.frameDuration);
    return minTime(lookahead, byBudget);
}

DecodePool::StepResult DecodePool::step(Stream &s, const DecodeTarget &target, const std::shared_ptr<AssetSlot> &slot,
                                        CMTime lookahead, size_t streamCount, bool reopen) {
    const AssetId asset = s.key.asset;
    if (reopen) {
        s.decoder.reset();
        s.rangeValid = false;
        s.extending = false;
        s.error.reset();
        s.openFailed = false;
    }
    // The hand-off: a forward stream about to seek (or to open a decoder and then seek) to the
    // picture its scrub lane decoded continues from that lane's decoder instead, or waits for the
    // lane's request of that picture to end (see the header comment).
    if (target.continueScrubLane && !target.generated && target.trackIndex < 0 &&
        target.direction == DecodeDirection::Forward && !s.findingEnd) {
        const CMTime at = clampToZero(target.sourceTime);
        const bool wouldSeek =
            !s.decoder || !s.rangeValid || at < s.rangeStart || at > s.rangeEnd + config_.seekAheadThreshold;
        if (wouldSeek) {
            switch (handOff(s, target, slot, at)) {
            case HandOff::Taken: return StepResult::Progress;
            case HandOff::Await: return StepResult::AwaitScrub;
            case HandOff::None: break;
            }
        }
    }
    if (!s.decoder) {
        s.openFailed = false; // Recomputed by this attempt (a transient failure may be over).
        s.error.reset();
        DecodeOptions options = config_.decodeOptions;
        options.interrupt = s.interrupt;
        if (target.generated) {
            // A generated picture: rendered by its source, no media to route (see the header comment).
            auto decoder = std::make_unique<GeneratedVideoDecoder>(target.generated);
            if (Status opened = decoder->open({}, -1, options); !opened.ok()) {
                if (opened.error().code == MediaErrorCode::Cancelled && s.interrupt->requested()) {
                    return StepResult::Progress; // interrupted, not failed: the next step renders again
                }
                s.error = opened.error();
                s.openFailed = true;
                os_log_error(poolLog(), "cannot render %{public}s: %{public}s",
                             target.generated->description().c_str(), opened.error().description().c_str());
                return StepResult::Settled;
            }
            s.decoder = std::move(decoder);
            s.backend = s.decoder->activeBackend();
            s.hardware = false;
            s.openedKey = target.generated->key();
            s.frameDuration = s.decoder->frameDuration(); // invalid for a static source, as for a still
            s.trackEnd = kCMTimeInvalid;
        } else {
            auto routed = slot->resolve(*router_);
            if (!routed.ok()) {
                s.error = routed.error();
                s.openFailed = true;
                return StepResult::Settled;
            }
            const RoutedMediaInfo &info = *routed.value();
            auto opened = router_->makeVideoDecoder(info, target.trackIndex, options);
            if (!opened.ok() && opened.error().code == MediaErrorCode::Cancelled && s.interrupt->requested()) {
                // Interrupted (a relink, a removal or a shutdown asked for it): not a failure of the
                // media. The next step opens again, whether or not the target moves meanwhile.
                return StepResult::Progress;
            }
            if (!opened.ok()) {
                s.error = opened.error();
                s.openFailed = true;
                if (opened.error().code != MediaErrorCode::Cancelled) { // Cancelled: we interrupted it.
                    os_log_error(poolLog(), "cannot open %{public}s: %{public}s", slot->url.c_str(),
                                 opened.error().description().c_str());
                }
                return StepResult::Settled;
            }
            s.decoder = std::move(opened.value().decoder);
            s.backend = opened.value().backend;
            s.hardware = s.decoder->usedHardware();
            s.openedKey = GeneratedKey{};
            setTrackTiming(s, info, target.trackIndex, *s.decoder);
        }
        s.videoEnd = kCMTimeInvalid;
        s.lastDecoded.reset();
        s.findingEnd = false;
        // A fresh decoder is positioned at the start of the stream.
        s.rangeValid = true;
        s.rangeStart = kCMTimeZero;
        s.rangeEnd = kCMTimeZero;
        s.continues = true;
        s.eof = false;
        s.firstAfterSeek = true;
        s.seekedTo = kCMTimeZero;
        s.repairedAt = kCMTimeInvalid;
        s.extending = false;
        s.error.reset();
        if (target.generated && target.generated->isStatic() &&
            cache_->contains(frameKey(asset, s.openedKey), kCMTimeZero)) {
            // A still generated picture already in the cache (the paused display's scrub rendered it as the edit
            // made it): nothing to render again. The range covers every time, as a held still's; should the picture
            // leave the cache, `lost` renders it again.
            s.rangeEnd = kCMTimePositiveInfinity;
            s.eof = true;
            return StepResult::Settled;
        }
        return StepResult::Progress;
    }

    const CMTime t = clampToZero(target.sourceTime);
    const CMTime window = effectiveWindow(s, lookahead, streamCount);
    s.window = window;

    // `findingEnd`: a seek of the search for the last frame (keeps the search state).
    auto seekTo = [&](CMTime to, bool findingEnd = false) {
        ++s.seeks;
        s.rangeValid = true;
        s.rangeStart = to;
        s.rangeEnd = to;
        s.continues = true;
        s.eof = false;
        s.firstAfterSeek = true;
        s.seekedTo = to;
        s.extending = false;
        s.lastDecoded.reset();
        s.findingEnd = findingEnd;
        if (!findingEnd) {
            s.tailProbe = kCMTimeInvalid;
            s.tailStep = kCMTimeInvalid;
        }
        Status st = s.decoder->seek(to);
        if (!st.ok()) {
            s.error = st.error();
            s.rangeValid = false;
            s.findingEnd = false;
            return StepResult::Settled;
        }
        return StepResult::Progress;
    };
    // End of the stream after the frames of the current range. The last frame is held: put
    // again with an infinite duration, its cache entry answers every time from its pts on, so a
    // clip that runs past the end of the video (a container whose audio lasts longer, a track
    // duration that overstates the pictures) shows the last picture, in playback and export alike,
    // instead of a missing layer. If the range has no frame (the seek landed at or after the end),
    // the last frame is searched for first, one seek per step (LastFrameSearch: back 2 frames, at least
    // 0.25 s, from where the stream ended, doubling the step, decoding forward to the end).
    auto reachedEnd = [&]() {
        s.eof = true;
        if (s.lastDecoded) {
            VideoFrame held = *s.lastDecoded;
            s.lastDecoded.reset();
            s.videoEnd = frameEnd(held, s.frameDuration);
            held.duration = kCMTimePositiveInfinity;
            publishStreamFrame(s, slot, held, s.frameDuration, held.pts);
            s.rangeEnd = kCMTimePositiveInfinity;
            s.findingEnd = false;
            s.tailProbe = kCMTimeInvalid;
            s.tailStep = kCMTimeInvalid;
            return StepResult::Settled;
        }
        CMTime from = s.findingEnd && isNumeric(s.tailProbe) ? s.tailProbe : s.seekedTo;
        if (!s.findingEnd && isNumeric(s.trackEnd) && isNumeric(from) && s.trackEnd < from) {
            from = s.trackEnd;
        }
        if (!isNumeric(from) || !(from > kCMTimeZero)) {
            s.findingEnd = false; // nothing before either: the stream has no frames
            return StepResult::Settled;
        }
        const CMTime step = s.findingEnd && isPositive(s.tailStep) ? LastFrameSearch::nextStep(s.tailStep)
                                                                   : LastFrameSearch::firstStep(s.frameDuration);
        const CMTime probe = LastFrameSearch::probe(from, step);
        s.tailStep = step;
        s.tailProbe = probe;
        return seekTo(probe, true);
    };
    // Re-positions the decoder at rangeEnd without forgetting the decoded range.
    auto resume = [&]() {
        ++s.seeks;
        s.extending = false;
        s.continues = true;
        s.firstAfterSeek = false;
        Status st = s.decoder->seek(s.rangeEnd);
        if (!st.ok()) {
            s.error = st.error();
            s.rangeValid = false;
            return StepResult::Settled;
        }
        return StepResult::Progress;
    };
    auto decodeOne = [&]() {
        auto r = s.decoder->next();
        if (!r.ok()) {
            if (r.error().code == MediaErrorCode::Cancelled) {
                // setTargets() moved the target away from this decode: nothing is lost (the
                // decoder resumes where it was if the target comes back) and the next step
                // re-reads the target.
                ++s.interrupts;
                return StepResult::Progress;
            }
            s.error = r.error();
            s.rangeValid = false;
            os_log_error(poolLog(), "decode error in %{public}s: %{public}s",
                         target.generated ? target.generated->description().c_str() : slot->url.c_str(),
                         r.error().description().c_str());
            return StepResult::Settled;
        }
        if (!r.value()) {
            if (s.extending) { // Cannot happen for a well-formed file; close the chunk.
                s.rangeStart = s.extendStart;
                s.extending = false;
                s.continues = false;
                return StepResult::Progress;
            }
            return reachedEnd();
        }
        const VideoFrame &f = *r.value();
        ++s.framesDecoded;
        s.hardware = f.wasHardwareDecoded;
        if (const std::string active = s.decoder->activeBackend(); !active.empty()) {
            s.backend = active; // The router's fallback decoder may have switched backends.
        }
        s.error.reset();
        if (s.frameBytes == 0) {
            s.frameBytes = FrameCache::bufferBytes(f.image.get());
        }
        // The first frame after a seek is the frame containing the seek target or, if the
        // target lies in a gap (before the first frame), the first frame after it: either way
        // it is what shows from the target on.
        const CMTime coverFrom = s.firstAfterSeek && isNumeric(s.seekedTo) && s.seekedTo < f.pts ? s.seekedTo : f.pts;
        publishStreamFrame(s, slot, f, s.frameDuration, coverFrom);
        const CMTime end = frameEnd(f, s.frameDuration);
        if (s.extending) {
            if (s.firstAfterSeek) {
                s.extendStart = minTime(s.extendStart, f.pts);
                s.firstAfterSeek = false;
            }
            if (end >= s.extendUntil) {
                s.rangeStart = s.extendStart;
                s.extending = false;
                s.continues = false;
            }
            return StepResult::Progress;
        }
        if (s.firstAfterSeek) {
            s.rangeStart = minTime(s.rangeStart, f.pts);
            s.firstAfterSeek = false;
        }
        s.rangeEnd = maxTime(s.rangeEnd, end);
        s.lastDecoded = f;
        return StepResult::Progress;
    };
    // The frame under the playhead is decoded but gone from the cache (memory pressure,
    // purge): re-decode it, once per target position.
    auto lost = [&](CMTime at) {
        return at < s.rangeEnd && !(isNumeric(s.repairedAt) && s.repairedAt == at) &&
               !cache_->contains(frameKey(asset, s.openedKey), at);
    };

    if (s.findingEnd && s.rangeValid && t >= s.rangeStart) {
        return decodeOne(); // searching for the last frame: decode on to the end
    }

    if (target.direction == DecodeDirection::Forward) {
        if (s.extending) {
            s.extending = false;
            s.continues = false;
        }
        if (!s.rangeValid || t < s.rangeStart || t > s.rangeEnd + config_.seekAheadThreshold) {
            return seekTo(t);
        }
        if (lost(t)) {
            const StepResult r = seekTo(t);
            s.repairedAt = t;
            return r;
        }
        if (s.eof || s.rangeEnd > t + window) {
            return StepResult::Settled;
        }
        if (!s.continues) {
            return resume();
        }
        return decodeOne();
    }

    // Backward: cover [t - window, t].
    const CMTime lowest = clampToZero(t - window);
    const CMTime coveredFrom = s.extending ? s.extendStart : s.rangeStart;
    if (!s.rangeValid || t < coveredFrom || lowest > s.rangeEnd + config_.seekAheadThreshold) {
        return seekTo(lowest);
    }
    if (lost(t)) {
        const StepResult r = seekTo(lowest);
        s.repairedAt = t;
        return r;
    }
    if (s.rangeEnd <= t && !s.eof) {
        // The frame under the playhead is not decoded yet: continue forward to it.
        if (s.extending || !s.continues) {
            return resume();
        }
        return decodeOne();
    }
    if (s.rangeStart <= lowest) {
        return StepResult::Settled;
    }
    if (!s.extending) {
        ++s.seeks;
        s.extendStart = maxTime(lowest, s.rangeStart - window);
        s.extendUntil = s.rangeStart;
        s.extending = true;
        s.firstAfterSeek = true;
        s.seekedTo = s.extendStart;
        s.continues = false;
        Status st = s.decoder->seek(s.extendStart);
        if (!st.ok()) {
            s.error = st.error();
            s.rangeValid = false;
            s.extending = false;
            return StepResult::Settled;
        }
        return StepResult::Progress;
    }
    return decodeOne();
}

void DecodePool::setTrackTiming(Stream &s, const RoutedMediaInfo &info, int trackIndex, const IVideoDecoder &decoder) {
    const TrackRoute *route = trackIndex < 0 ? info.visualRoute() : info.route(trackIndex);
    const TrackInfo *track = route ? info.info.track(route->trackIndex) : nullptr;
    s.frameDuration = track && track->kind == TrackKind::Still ? kCMTimeInvalid
                      : track && isPositive(track->frameDuration) ? track->frameDuration
                                                                  : decoder.frameDuration();
    s.trackEnd = track && track->kind != TrackKind::Still && isNumeric(track->duration)
                     ? (isNumeric(track->startTime) ? track->startTime : kCMTimeZero) + track->duration
                     : kCMTimeInvalid;
}

// MARK: - Hand-off

bool DecodePool::scrubWillPositionLocked(const DecodeTarget &target, CMTime t) const {
    if (!target.continueScrubLane || target.generated) {
        return false;
    }
    const ScrubKey key{target.asset, *target.continueScrubLane};
    if (scrubBusy_ && scrubInFlight_ == key && scrubInFlightGenerated_ == GeneratedKey{} &&
        CMTimeCompare(scrubInFlightTime_, t) == 0) {
        return true; // being decoded
    }
    const auto pending = scrubPending_.find(key);
    if (pending == scrubPending_.end() || pending->second.generated ||
        CMTimeCompare(clampToZero(pending->second.time), t) != 0) {
        return false;
    }
    // Pending: worth waiting for only when it is next in line (the one scrub thread serves the lanes one at a
    // time). Behind another lane's request (the other picture of a dissolve, a picture in picture) the stream
    // decodes its picture itself, in parallel; the request then finds it in the cache.
    if (scrubBusy_) {
        return scrubInFlight_ == key; // its own lane's older request is superseded by it
    }
    const auto oldest = std::min_element(scrubPending_.begin(), scrubPending_.end(), [](const auto &a, const auto &b) {
        return a.second.sequence < b.second.sequence;
    });
    return oldest->first == key;
}

bool DecodePool::releaseScrubWaitersLocked() {
    bool released = false;
    for (auto &[key, stream] : streams_) {
        if (stream->awaitingScrub) {
            stream->awaitingScrub = false;
            released = true;
        }
    }
    return released;
}

DecodePool::HandOff DecodePool::handOff(Stream &s, const DecodeTarget &target, const std::shared_ptr<AssetSlot> &slot,
                                        CMTime t) {
    if (!target.continueScrubLane || target.generated || target.trackIndex >= 0) {
        return HandOff::None;
    }
    // The track's timing comes from the routing the scrub decoder was opened with (already resolved:
    // no probe).
    auto routed = slot->resolve(*router_);
    if (!routed.ok()) {
        return HandOff::None;
    }
    std::unique_ptr<ScrubDecoder> taken;
    std::unique_ptr<IVideoDecoder> dropped; // destroyed outside the lock
    {
        // One decision under one lock: whether the lane's decoder can be taken now, else whether its request
        // for this picture is coming (between two separate looks the request could end, leaving neither).
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || s.removed || slot->retired || slot->epoch != epoch_) {
            return HandOff::None;
        }
        const ScrubKey key{s.key.asset, *target.continueScrubLane};
        const auto it = scrubDecoders_.find(key);
        const bool takeable = [&] {
            if (scrubBusy_ && scrubInFlight_ == key) {
                return false; // the scrub thread is using it (and owns its fields)
            }
            if (it == scrubDecoders_.end()) {
                return false;
            }
            const ScrubDecoder &d = *it->second;
            if (!d.positioned || d.slot != slot || d.generated != GeneratedKey{} || !d.decoder) {
                return false;
            }
            if (const auto pending = scrubPending_.find(key);
                pending != scrubPending_.end() &&
                (pending->second.generated || CMTimeCompare(clampToZero(pending->second.time), t) != 0)) {
                return false; // the lane is about to seek it elsewhere
            }
            return d.coverFrom <= t && t < d.end; // else positioned after another picture
        }();
        if (!takeable) {
            return scrubWillPositionLocked(target, t) ? HandOff::Await : HandOff::None;
        }
        taken = std::move(it->second);
        if (s.decoder && s.openedKey == GeneratedKey{}) {
            // The stream's own decoder goes to the lane in exchange (its position does not matter: a
            // scrub always seeks), with the interrupt it was opened with.
            auto parked = std::make_unique<ScrubDecoder>();
            parked->decoder = std::move(s.decoder);
            parked->slot = slot;
            parked->interrupt = s.interrupt;
            parked->backend = s.backend;
            parked->lastUse = ++scrubUseCounter_;
            it->second = std::move(parked);
        } else {
            scrubDecoders_.erase(it);
            dropped = std::move(s.decoder);
        }
        // The decoder keeps the interrupt it was opened with; a request made of the stream's old one
        // (its target moved meanwhile) carries over.
        const bool interrupted = s.interrupt->requested();
        s.interrupt = taken->interrupt ? taken->interrupt : std::make_shared<DecodeInterrupt>();
        if (interrupted) {
            s.interrupt->request();
        } else {
            s.interrupt->clear();
        }
    }
    dropped.reset();
    VideoFrame f = taken->delivered;
    // The picture itself is in the cache (the request put it, and its requester keeps it pinned while it
    // is shown).
    if (FrameCache::PinnedFrame cached = cache_->acquire(frameKey(s.key.asset), f.pts)) {
        f.image = cached.image();
    }
    s.decoder = std::move(taken->decoder);
    s.backend = taken->backend;
    s.hardware = f.wasHardwareDecoded;
    s.openedKey = GeneratedKey{};
    setTrackTiming(s, *routed.value(), target.trackIndex, *s.decoder);
    s.openFailed = false;
    s.error.reset();
    s.videoEnd = kCMTimeInvalid;
    s.findingEnd = false;
    s.tailProbe = kCMTimeInvalid;
    s.tailStep = kCMTimeInvalid;
    s.extending = false;
    s.eof = false;
    s.repairedAt = kCMTimeInvalid;
    // As if the stream had sought to the request's time and decoded its first frame (step's seekTo
    // and decodeOne): the range covers the picture from the time sought, the decoder continues after it.
    s.rangeValid = true;
    s.seekedTo = taken->requestTime;
    s.rangeStart = minTime(taken->requestTime, f.pts);
    s.rangeEnd = maxTime(taken->requestTime, taken->end);
    s.continues = true;
    s.firstAfterSeek = false;
    if (f.image) {
        s.lastDecoded = f; // held should the stream end right after it
        if (s.frameBytes == 0) {
            s.frameBytes = FrameCache::bufferBytes(f.image.get());
        }
    } else {
        // Evicted since (it was not shown): the next step finds it lost and decodes it again.
        s.lastDecoded.reset();
    }
    ++s.handoffs;
    return HandOff::Taken;
}

// MARK: - Scrub

void DecodePool::requestFrame(AssetId asset, CMTime time, ScrubCallback callback, uint64_t lane,
                              std::shared_ptr<const GeneratedPictureSource> generated) {
    if (!callback) {
        return;
    }
    bool accepted = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!stopping_) {
            accepted = true;
            ++scrubRequests_;
            if (generated && asset.isValid()) {
                slotFor(asset, {}); // a generator asset is never registered: its slot holds the epoch
            }
            const ScrubKey key{asset, lane};
            // A request for the picture being decoded does not throw that decode away: it waits and
            // is answered from the cache (a playhead that stops where it was scrubbed asks again).
            const bool samePicture = scrubBusy_ && scrubInFlight_ == key &&
                                     CMTimeCompare(scrubInFlightTime_, clampToZero(time)) == 0 &&
                                     scrubInFlightGenerated_ == (generated ? generated->key() : GeneratedKey{});
            auto it = scrubPending_.find(key);
            if (it != scrubPending_.end()) {
                scrubToCancel_.push_back(std::move(it->second.callback));
                it->second = ScrubRequest{time, std::move(callback), ++scrubSequence_, std::move(generated)};
            } else {
                scrubPending_.emplace(key,
                                      ScrubRequest{time, std::move(callback), ++scrubSequence_, std::move(generated)});
            }
            if (scrubBusy_ && scrubInFlight_ == key && scrubInterrupt_ && !samePicture) {
                scrubInterrupt_->request(); // The request being decoded is superseded.
            }
            if (!scrubThread_.joinable()) {
                scrubThread_ = std::thread([this] { scrubMain(); });
            }
        }
    }
    if (!accepted) { // The pool is shutting down.
        callback(cancelledError());
        return;
    }
    scrubCv_.notify_one();
}

void DecodePool::dropRetiredScrubDecoders(std::unique_lock<std::mutex> &lock) {
    std::vector<std::unique_ptr<ScrubDecoder>> dead;
    for (auto it = scrubDecoders_.begin(); it != scrubDecoders_.end();) {
        if (it->second->slot->retired) {
            dead.push_back(std::move(it->second));
            it = scrubDecoders_.erase(it);
        } else {
            ++it;
        }
    }
    scrubCleanupPending_ = false;
    lock.unlock();
    dead.clear(); // Closes the files outside the lock.
    lock.lock();
    progressCv_.notify_all();
}

void DecodePool::scrubMain() {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        if (scrubCleanupPending_) {
            dropRetiredScrubDecoders(lock);
        }
        if (stopping_) {
            for (auto &[key, request] : scrubPending_) {
                scrubToCancel_.push_back(std::move(request.callback));
            }
            scrubPending_.clear();
        }
        if (!scrubToCancel_.empty()) {
            std::vector<ScrubCallback> cancelled;
            cancelled.swap(scrubToCancel_);
            scrubCancelled_ += cancelled.size();
            lock.unlock();
            for (ScrubCallback &cb : cancelled) {
                cb(cancelledError());
            }
            cancelled.clear();
            lock.lock();
            if (releaseScrubWaitersLocked()) {
                workCv_.notify_all(); // a stream waiting for a superseded request decides again
            }
            progressCv_.notify_all();
            continue;
        }
        if (stopping_) {
            break;
        }
        if (scrubPending_.empty()) {
            scrubCv_.wait(lock);
            continue;
        }
        auto oldest = std::min_element(scrubPending_.begin(), scrubPending_.end(), [](const auto &a, const auto &b) {
            return a.second.sequence < b.second.sequence;
        });
        const ScrubKey key = oldest->first;
        ScrubRequest request = std::move(oldest->second);
        scrubPending_.erase(oldest);
        auto slotIt = assets_.find(key.asset);
        std::shared_ptr<AssetSlot> slot = slotIt != assets_.end() ? slotIt->second : nullptr;
        scrubBusy_ = true;
        scrubInFlight_ = key;
        scrubInFlightTime_ = clampToZero(request.time);
        scrubInFlightGenerated_ = request.generated ? request.generated->key() : GeneratedKey{};
        if (auto dec = scrubDecoders_.find(key); dec != scrubDecoders_.end()) {
            scrubInterrupt_ = dec->second->interrupt;
        } else {
            scrubInterrupt_ = std::make_shared<DecodeInterrupt>();
        }
        scrubInterrupt_->clear();
        lock.unlock();

        bool ok = false;
        bool cancelled = false;
        @autoreleasepool {
            Result<ScrubFrame> result =
                !slot ? Result<ScrubFrame>(
                            makeError(MediaErrorCode::InvalidArgument, "requestFrame: unknown asset (no path)"))
                : request.generated ? serviceGeneratedScrub(key, slot, request.time, request.generated)
                                    : serviceScrub(key, slot, request.time);
            ok = result.ok();
            cancelled = !ok && result.error().code == MediaErrorCode::Cancelled;
            request.callback(cancelled ? Result<ScrubFrame>(cancelledError()) : std::move(result));
            request.callback = nullptr;
        }

        lock.lock();
        scrubBusy_ = false;
        scrubInterrupt_.reset();
        ++(ok ? scrubServiced_ : cancelled ? scrubCancelled_ : scrubFailed_);
        if (releaseScrubWaitersLocked()) {
            workCv_.notify_all(); // the hand-off is ready (or did not happen): the waiting streams step
        }
        progressCv_.notify_all();
    }
    std::map<ScrubKey, std::unique_ptr<ScrubDecoder>> decoders;
    decoders.swap(scrubDecoders_);
    lock.unlock();
    decoders.clear();
}

Result<ScrubFrame> DecodePool::serviceScrub(const ScrubKey &key, const std::shared_ptr<AssetSlot> &slot, CMTime time) {
    time = clampToZero(time);
    auto routed = slot->resolve(*router_);
    if (!routed.ok()) {
        return std::move(routed).error();
    }
    const RoutedMediaInfo &info = *routed.value();
    const TrackRoute *route = info.visualRoute();
    const TrackInfo *track = route ? info.info.track(route->trackIndex) : nullptr;
    if (track == nullptr) {
        return makeError(MediaErrorCode::NoSuchTrack, "no video track in " + slot->url);
    }
    const CMTime fd = track->kind == TrackKind::Still ? kCMTimeInvalid : track->frameDuration;

    if (FrameCache::PinnedFrame cached =
            cache_->acquire(frameKey(key.asset), track->kind == TrackKind::Still ? kCMTimeZero : time)) {
        const FrameCache::Frame &hit = cached.frame();
        return ScrubFrame{hit.image, hit.pts, hit.duration, hit.index, true, std::move(cached)};
    }

    const DecoderMaker open = [&](std::string &backend) -> Result<std::unique_ptr<IVideoDecoder>> {
        auto opened = router_->makeVideoDecoder(info, route->trackIndex, [&] {
            DecodeOptions options = config_.decodeOptions;
            std::lock_guard<std::mutex> lock(mutex_);
            options.interrupt = scrubInterrupt_;
            return options;
        }());
        if (!opened.ok()) {
            return std::move(opened).error();
        }
        backend = opened.value().backend;
        return std::move(opened.value().decoder);
    };
    auto made = scrubDecoderFor(key, slot, GeneratedKey{}, open);
    if (!made.ok()) {
        return std::move(made).error();
    }
    ScrubDecoder &d = *made.value(); // not positioned (scrubDecoderFor), until it delivers the picture below

    auto decodeAt = [&](CMTime at) -> Result<std::optional<VideoFrame>> {
        Status st = d.decoder->seek(at);
        if (!st.ok()) {
            return std::move(st).error();
        }
        return d.decoder->next();
    };
    // Past the end: the last frame, as a scrub to the end of a clip expects (LastFrameSearch, as the
    // streams find it in step()).
    auto frame = decodeAt(time);
    bool pastEnd = false;
    if (frame.ok() && !frame.value() && track->kind != TrackKind::Still) {
        frame = LastFrameSearch::run(*d.decoder, LastFrameSearch::searchFrom(time, track->startTime, track->duration),
                                     fd);
        pastEnd = true;
    }
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    if (!frame.value()) {
        return makeError(MediaErrorCode::InvalidArgument, "no frame at or after the requested time in " + slot->url);
    }
    const VideoFrame &f = *frame.value();
    FrameCache::PinnedFrame pin;
    {
        // Checked and put under mutex_ (see publishStreamFrame): a frame of a file the asset no
        // longer names is neither cached nor delivered. Put pinned: the requester is about to show
        // it, and the eviction order (the streams' focus) may still name where the playhead was.
        std::lock_guard<std::mutex> lock(mutex_);
        if (slot->retired || slot->epoch != epoch_) {
            return cancelledError();
        }
        if (pastEnd) {
            // The last frame holds for every later time (as the streams hold it at the end).
            VideoFrame held = f;
            held.duration = kCMTimePositiveInfinity;
            pin = cache_->putPinned(slot->epoch, frameKey(key.asset), held, fd, held.pts);
        } else {
            pin = cache_->putPinned(slot->epoch, frameKey(key.asset), f, fd, time < f.pts ? time : f.pts);
            // Positioned right after the picture: a stream starting here can take the decoder over.
            d.positioned = true;
            d.requestTime = time;
            d.coverFrom = time < f.pts ? time : f.pts;
            d.end = frameEnd(f, fd);
            d.delivered = f;
            d.delivered.image = PixelBuffer{};
        }
    }
    return ScrubFrame{f.image, f.pts, f.duration, FrameCache::frameIndex(f.pts, fd), false, std::move(pin)};
}

Result<DecodePool::ScrubDecoder *>
DecodePool::scrubDecoderFor(const ScrubKey &key, const std::shared_ptr<AssetSlot> &slot, const GeneratedKey &generated,
                            const DecoderMaker &make) {
    // The interrupt the scrub thread armed for this request (requestFrame() requests it when a
    // newer request for the same key arrives); `make` gives it to the decoder it opens. The map is
    // touched under mutex_ (a worker may take a parked decoder over, see handOff); the
    // entry of `key` is this thread's while it services the request (scrubInFlight_), so the pointer
    // returned stays valid until the request ends.
    std::shared_ptr<DecodeInterrupt> interrupt;
    std::unique_ptr<ScrubDecoder> stale;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        interrupt = scrubInterrupt_;
        const auto it = scrubDecoders_.find(key);
        if (it != scrubDecoders_.end()) {
            if (it->second->slot == slot && it->second->generated == generated) {
                it->second->lastUse = ++scrubUseCounter_;
                it->second->positioned = false; // this request moves it; set again once it delivered the picture
                return it->second.get();
            }
            stale = std::move(it->second);
            scrubDecoders_.erase(it);
        }
    }
    stale.reset(); // closes the file outside the lock
    std::string backend;
    auto opened = make(backend);
    if (!opened.ok()) {
        return std::move(opened).error();
    }
    auto entry = std::make_unique<ScrubDecoder>();
    entry->decoder = std::move(opened).value();
    entry->backend = std::move(backend);
    entry->slot = slot;
    entry->generated = generated;
    entry->interrupt = interrupt;
    ScrubDecoder *d = entry.get();
    std::vector<std::unique_ptr<ScrubDecoder>> evicted;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (const auto it = scrubDecoders_.find(key); it != scrubDecoders_.end()) {
            evicted.push_back(std::move(it->second)); // not expected: nothing parks under a key in flight
        }
        scrubDecoders_[key] = std::move(entry);
        while (scrubDecoders_.size() > static_cast<size_t>(config_.maxScrubDecoders)) {
            // Least recently used, never the one just opened.
            auto age = [&](const auto &e) { return e.first == key ? UINT64_MAX : e.second->lastUse; };
            auto lru = std::min_element(scrubDecoders_.begin(), scrubDecoders_.end(),
                                        [&](const auto &a, const auto &b) { return age(a) < age(b); });
            evicted.push_back(std::move(lru->second));
            scrubDecoders_.erase(lru);
        }
        d->lastUse = ++scrubUseCounter_;
    }
    evicted.clear();
    return d;
}

Result<ScrubFrame> DecodePool::serviceGeneratedScrub(const ScrubKey &key, const std::shared_ptr<AssetSlot> &slot,
                                                     CMTime time,
                                                     const std::shared_ptr<const GeneratedPictureSource> &generated) {
    const GeneratedKey generatedKey = generated->key();
    const FrameKey cacheKey = frameKey(key.asset, generatedKey);
    const bool still = generated->isStatic();
    const CMTime fd = still ? kCMTimeInvalid : generated->frameDuration();
    const CMTime at = still ? kCMTimeZero : clampToZero(time);
    if (FrameCache::PinnedFrame cached = cache_->acquire(cacheKey, at)) {
        const FrameCache::Frame &hit = cached.frame();
        return ScrubFrame{hit.image, hit.pts, hit.duration, hit.index, true, std::move(cached)};
    }
    const DecoderMaker open = [&](std::string &backend) -> Result<std::unique_ptr<IVideoDecoder>> {
        auto decoder = std::make_unique<GeneratedVideoDecoder>(generated);
        DecodeOptions options = config_.decodeOptions;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            options.interrupt = scrubInterrupt_;
        }
        VE_MEDIA_TRY(decoder->open({}, -1, options));
        backend = decoder->activeBackend();
        return std::unique_ptr<IVideoDecoder>(std::move(decoder));
    };
    auto made = scrubDecoderFor(key, slot, generatedKey, open);
    if (!made.ok()) {
        return std::move(made).error();
    }
    IVideoDecoder &decoder = *made.value()->decoder;
    VE_MEDIA_TRY(decoder.seek(at));
    auto frame = decoder.next();
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    if (!frame.value()) {
        return makeError(MediaErrorCode::Internal, generated->description() + " rendered no picture");
    }
    const VideoFrame &f = *frame.value();
    FrameCache::PinnedFrame pin;
    {
        // Checked and put under mutex_ (see publishStreamFrame): a picture rendered for an earlier media
        // epoch is neither cached nor delivered. Put pinned: the requester is about to show it.
        std::lock_guard<std::mutex> lock(mutex_);
        if (slot->retired || slot->epoch != epoch_) {
            return cancelledError();
        }
        pin = cache_->putPinned(slot->epoch, cacheKey, f, fd, f.pts);
    }
    return ScrubFrame{f.image, f.pts, f.duration, FrameCache::frameIndex(f.pts, fd), false, std::move(pin)};
}

// MARK: - Observation

bool DecodePool::waitUntilIdle(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return progressCv_.wait_for(lock, timeout, [&] {
        if (!scrubPending_.empty() || !scrubToCancel_.empty() || scrubBusy_ || !retired_.empty() || retiring_ > 0 ||
            stepsInFlight_ > 0 || scrubCleanupPending_) {
            return false;
        }
        if (suspended_) {
            return true; // held: nothing more happens until the next setTargets()
        }
        for (const auto &[key, stream] : streams_) {
            if (stream->busy || !stream->idle) {
                return false;
            }
        }
        return true;
    });
}

bool DecodePool::waitForProgress(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return progressCv_.wait_for(lock, timeout) == std::cv_status::no_timeout;
}

void DecodePool::refresh() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto &[key, stream] : streams_) {
            if (stream->failed && !stream->failedTransient) {
                continue;
            }
            ++stream->generation;
            stream->idle = false;
            stream->failed = false;
            stream->rearmRepair = true; // the worker re-arms the repair of an evicted playhead frame
        }
    }
    workCv_.notify_all();
}

DecodePool::Stats DecodePool::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    Stats st;
    for (const auto &[key, stream] : streams_) {
        StreamStats s = stream->published;
        s.idle = stream->idle;
        s.failed = stream->failed;
        s.awaitingScrub = stream->awaitingScrub;
        s.target = stream->target.sourceTime;
        st.streams.push_back(std::move(s));
    }
    st.suspended = suspended_;
    st.workerThreads = static_cast<int>(workers_.size());
    st.scrubRequests = scrubRequests_;
    st.scrubServiced = scrubServiced_;
    st.scrubCancelled = scrubCancelled_;
    st.scrubFailed = scrubFailed_;
    return st;
}

} // namespace ve::media
