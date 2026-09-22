#include "DecodePool.h"

#include "../Model/TimeUtil.h"

#include <os/log.h>

#include <algorithm>

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

} // namespace

// MARK: - Internal types

struct DecodePool::AssetSlot {
    explicit AssetSlot(std::string path) : url(std::move(path)) {}
    AssetSlot(std::string path, RoutedMediaInfo info)
        : url(std::move(path)), resolved(true), routed(std::make_shared<const RoutedMediaInfo>(std::move(info))) {}

    const std::string url; ///< Immutable: readable without `mutex`.

    /// Routes the asset once (blocking; concurrent callers wait for the first).
    Result<std::shared_ptr<const RoutedMediaInfo>> resolve(const BackendRouter &router) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!resolved) {
            if (url.empty()) {
                error = makeError(MediaErrorCode::InvalidArgument, "no media path registered for the asset");
            } else {
                auto r = router.probe(url);
                if (r.ok()) {
                    routed = std::make_shared<const RoutedMediaInfo>(std::move(r).value());
                } else {
                    error = std::move(r).error();
                }
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
    bool failed = false;     ///< Open failed; stays idle until reopened.
    bool reopen = false;     ///< Drop the decoder before the next step.
    uint64_t lastServed = 0;
    StreamStats published;

    // Owned by the worker that set `busy` (no lock needed while busy).
    std::unique_ptr<IVideoDecoder> decoder;
    CMTime frameDuration = kCMTimeInvalid;
    std::string backend;
    bool hardware = false;
    bool rangeValid = false; ///< [rangeStart, rangeEnd) is decoded into the cache.
    CMTime rangeStart = kCMTimeZero;
    CMTime rangeEnd = kCMTimeZero;
    bool continues = false;  ///< The decoder's next frame starts at rangeEnd.
    bool eof = false;        ///< rangeEnd is the end of the stream.
    bool firstAfterSeek = false;
    bool repairUsed = false; ///< A lost frame was re-decoded since the last seek.
    bool extending = false;  ///< Backward: decoding [extendStart, extendUntil) below the range.
    CMTime extendStart = kCMTimeZero;
    CMTime extendUntil = kCMTimeZero;
    bool openFailed = false;
    uint64_t framesDecoded = 0;
    uint64_t seeks = 0;
    std::optional<MediaError> error;
};

struct DecodePool::ScrubDecoder {
    std::unique_ptr<IVideoDecoder> decoder;
    std::shared_ptr<AssetSlot> slot;
    uint64_t lastUse = 0;
};

// MARK: - Lifetime

DecodePool::DecodePool(std::shared_ptr<BackendRouter> router, std::shared_ptr<FrameCache> cache)
    : DecodePool(std::move(router), std::move(cache), Config{}) {}

DecodePool::DecodePool(std::shared_ptr<BackendRouter> router, std::shared_ptr<FrameCache> cache, Config config)
    : router_(std::move(router)), cache_(std::move(cache)), config_([&] {
          Config c = config;
          c.maxThreads = std::max(1, c.maxThreads);
          c.maxScrubDecoders = std::max(1, c.maxScrubDecoders);
          if (!isPositive(c.lookahead)) {
              c.lookahead = CMTimeMake(1, 1);
          }
          if (!isNumeric(c.seekAheadThreshold) || c.seekAheadThreshold < kCMTimeZero) {
              c.seekAheadThreshold = kCMTimeZero;
          }
          return c;
      }()),
      lookahead_(config_.lookahead) {}

DecodePool::~DecodePool() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
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
}

// MARK: - Assets

std::shared_ptr<DecodePool::AssetSlot> DecodePool::slotFor(AssetId asset, const std::string &url) {
    auto it = assets_.find(asset);
    if (it != assets_.end() && (url.empty() || url == it->second->url)) {
        return it->second;
    }
    auto slot = std::make_shared<AssetSlot>(url);
    const bool relinked = it != assets_.end();
    assets_[asset] = slot;
    if (relinked) {
        for (auto &[key, stream] : streams_) {
            if (key.asset == asset) {
                stream->slot = slot;
                stream->reopen = true;
                stream->failed = false;
                stream->idle = false;
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
        auto slot = routed ? std::make_shared<AssetSlot>(url, std::move(*routed)) : std::make_shared<AssetSlot>(url);
        assets_[asset] = slot;
        for (auto &[key, stream] : streams_) {
            if (key.asset == asset) {
                stream->slot = slot;
                if (!sameUrl) {
                    stream->reopen = true;
                    stream->failed = false;
                    stream->idle = false;
                    ++stream->generation;
                }
            }
        }
    }
    workCv_.notify_all();
}

void DecodePool::invalidate(AssetId asset) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = assets_.find(asset);
        if (it == assets_.end()) {
            return;
        }
        auto slot = std::make_shared<AssetSlot>(it->second->url);
        it->second = slot;
        for (auto &[key, stream] : streams_) {
            if (key.asset == asset) {
                stream->slot = slot;
                stream->reopen = true;
                stream->failed = false;
                stream->idle = false;
                ++stream->generation;
            }
        }
    }
    workCv_.notify_all();
}

// MARK: - Targets

void DecodePool::setTargets(std::vector<DecodeTarget> targets) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) {
            return;
        }
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
                const bool moved =
                    t.sourceTime != stream->target.sourceTime || t.direction != stream->target.direction;
                stream->target = std::move(t);
                if (moved && !stream->failed) {
                    ++stream->generation;
                    stream->idle = false;
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
                if (!stream->busy) {
                    retired_.push_back(stream);
                }
            }
        }
        streams_.swap(next);
        ensureWorkers();
    }
    workCv_.notify_all();
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

void DecodePool::ensureWorkers() {
    const size_t wanted = std::min(static_cast<size_t>(config_.maxThreads), streams_.size());
    while (workers_.size() < wanted) {
        workers_.emplace_back([this] { workerMain(); });
    }
}

// MARK: - Workers

DecodePool::Stream *DecodePool::pickStream() {
    Stream *best = nullptr;
    for (auto &[key, stream] : streams_) {
        Stream *s = stream.get();
        if (s->busy || s->idle) {
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
    p.framesDecoded = s.framesDecoded;
    p.seeks = s.seeks;
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
        s->busy = true;
        s->lastServed = ++tick_;
        const DecodeTarget target = s->target;
        const uint64_t generation = s->generation;
        const std::shared_ptr<AssetSlot> slot = s->slot;
        const CMTime window = lookahead_;
        const bool reopen = std::exchange(s->reopen, false);
        lock.unlock();

        const StepResult result = step(*s, target, slot, window, reopen);

        lock.lock();
        s->busy = false;
        if (s->openFailed) {
            s->failed = true;
        }
        if (result == StepResult::Settled && s->generation == generation) {
            s->idle = true;
        }
        publish(*s);
        if (s->removed) {
            retired_.push_back(std::move(keep));
        }
        progressCv_.notify_all();
    }
}

DecodePool::StepResult DecodePool::step(Stream &s, const DecodeTarget &target, const std::shared_ptr<AssetSlot> &slot,
                                        CMTime window, bool reopen) {
    const AssetId asset = s.key.asset;
    if (reopen) {
        s.decoder.reset();
        s.rangeValid = false;
        s.extending = false;
        s.error.reset();
        s.openFailed = false;
    }
    if (!s.decoder) {
        auto routed = slot->resolve(*router_);
        if (!routed.ok()) {
            s.error = routed.error();
            s.openFailed = true;
            return StepResult::Settled;
        }
        const RoutedMediaInfo &info = *routed.value();
        auto opened = router_->makeVideoDecoder(info, target.trackIndex, config_.decodeOptions);
        if (!opened.ok()) {
            s.error = opened.error();
            s.openFailed = true;
            os_log_error(poolLog(), "cannot open %{public}s: %{public}s", slot->url.c_str(),
                         opened.error().description().c_str());
            return StepResult::Settled;
        }
        s.decoder = std::move(opened.value().decoder);
        s.backend = opened.value().backend;
        s.hardware = s.decoder->usedHardware();
        const TrackRoute *route = target.trackIndex < 0 ? info.visualRoute() : info.route(target.trackIndex);
        const TrackInfo *track = route ? info.info.track(route->trackIndex) : nullptr;
        s.frameDuration = track && track->kind == TrackKind::Still ? kCMTimeInvalid
                          : track && isPositive(track->frameDuration) ? track->frameDuration
                                                                      : s.decoder->frameDuration();
        // A fresh decoder is positioned at the start of the stream.
        s.rangeValid = true;
        s.rangeStart = kCMTimeZero;
        s.rangeEnd = kCMTimeZero;
        s.continues = true;
        s.eof = false;
        s.firstAfterSeek = true;
        s.repairUsed = false;
        s.extending = false;
        s.error.reset();
        return StepResult::Progress;
    }

    const CMTime t = clampToZero(target.sourceTime);

    auto seekTo = [&](CMTime to) {
        ++s.seeks;
        s.rangeValid = true;
        s.rangeStart = to;
        s.rangeEnd = to;
        s.continues = true;
        s.eof = false;
        s.firstAfterSeek = true;
        s.repairUsed = false;
        s.extending = false;
        Status st = s.decoder->seek(to);
        if (!st.ok()) {
            s.error = st.error();
            s.rangeValid = false;
            return StepResult::Settled;
        }
        return StepResult::Progress;
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
            s.error = r.error();
            s.rangeValid = false;
            os_log_error(poolLog(), "decode error in %{public}s: %{public}s", slot->url.c_str(),
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
            s.eof = true;
            return StepResult::Settled;
        }
        const VideoFrame &f = *r.value();
        ++s.framesDecoded;
        s.hardware = f.wasHardwareDecoded;
        s.error.reset();
        cache_->put(asset, f, s.frameDuration);
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
        return StepResult::Progress;
    };
    auto lost = [&](CMTime at) {
        return at < s.rangeEnd && !s.repairUsed &&
               !cache_->contains(asset, FrameCache::frameIndex(at, s.frameDuration));
    };

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
            s.repairUsed = true;
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
        s.repairUsed = true;
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

// MARK: - Scrub

void DecodePool::requestFrame(AssetId asset, CMTime time, ScrubCallback callback) {
    if (!callback) {
        return;
    }
    bool accepted = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!stopping_) {
            accepted = true;
            ++scrubRequests_;
            auto it = scrubPending_.find(asset);
            if (it != scrubPending_.end()) {
                scrubToCancel_.push_back(std::move(it->second.callback));
                it->second = ScrubRequest{time, std::move(callback), ++scrubSequence_};
            } else {
                scrubPending_.emplace(asset, ScrubRequest{time, std::move(callback), ++scrubSequence_});
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

void DecodePool::scrubMain() {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        if (stopping_) {
            for (auto &[asset, request] : scrubPending_) {
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
        const AssetId asset = oldest->first;
        ScrubRequest request = std::move(oldest->second);
        scrubPending_.erase(oldest);
        auto slotIt = assets_.find(asset);
        std::shared_ptr<AssetSlot> slot = slotIt != assets_.end() ? slotIt->second : nullptr;
        scrubBusy_ = true;
        lock.unlock();

        Result<ScrubFrame> result = slot ? serviceScrub(asset, slot, request.time)
                                         : Result<ScrubFrame>(makeError(MediaErrorCode::InvalidArgument,
                                                                        "requestFrame: unknown asset (no path)"));
        const bool ok = result.ok();
        request.callback(std::move(result));
        request.callback = nullptr;

        lock.lock();
        scrubBusy_ = false;
        ++(ok ? scrubServiced_ : scrubFailed_);
        progressCv_.notify_all();
    }
    lock.unlock();
    scrubDecoders_.clear();
}

Result<ScrubFrame> DecodePool::serviceScrub(AssetId asset, const std::shared_ptr<AssetSlot> &slot, CMTime time) {
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

    if (auto cached = cache_->get(asset, FrameCache::frameIndex(time, fd))) {
        return ScrubFrame{cached->image, cached->pts, cached->duration, cached->index, true};
    }

    auto &entry = scrubDecoders_[asset];
    if (!entry || entry->slot != slot) {
        entry.reset();
        auto opened = router_->makeVideoDecoder(info, route->trackIndex, config_.decodeOptions);
        if (!opened.ok()) {
            scrubDecoders_.erase(asset);
            return std::move(opened).error();
        }
        entry = std::make_unique<ScrubDecoder>();
        entry->decoder = std::move(opened.value().decoder);
        entry->slot = slot;
        while (scrubDecoders_.size() > static_cast<size_t>(config_.maxScrubDecoders)) {
            // Least recently used, never the one just opened.
            auto age = [&](const auto &entry) { return entry.first == asset ? UINT64_MAX : entry.second->lastUse; };
            auto lru = std::min_element(scrubDecoders_.begin(), scrubDecoders_.end(),
                                        [&](const auto &a, const auto &b) { return age(a) < age(b); });
            scrubDecoders_.erase(lru);
        }
    }
    ScrubDecoder &d = *scrubDecoders_.at(asset);
    d.lastUse = ++scrubUseCounter_;

    auto decodeAt = [&](CMTime at) -> Result<std::optional<VideoFrame>> {
        Status st = d.decoder->seek(at);
        if (!st.ok()) {
            return std::move(st).error();
        }
        return d.decoder->next();
    };
    auto frame = decodeAt(time);
    if (frame.ok() && !frame.value() && isPositive(fd) && isNumeric(track->duration)) {
        // Past the end: show the last frame, as a scrub to the end of a clip expects.
        frame = decodeAt(clampToZero(track->startTime + track->duration - fd));
    }
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    if (!frame.value()) {
        return makeError(MediaErrorCode::InvalidArgument, "no frame at or after the requested time in " + slot->url);
    }
    const VideoFrame &f = *frame.value();
    cache_->put(asset, f, fd);
    return ScrubFrame{f.image, f.pts, f.duration, FrameCache::frameIndex(f.pts, fd), false};
}

// MARK: - Observation

bool DecodePool::waitUntilIdle(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return progressCv_.wait_for(lock, timeout, [&] {
        if (!scrubPending_.empty() || !scrubToCancel_.empty() || scrubBusy_ || !retired_.empty() || retiring_ > 0) {
            return false;
        }
        for (const auto &[key, stream] : streams_) {
            if (stream->busy || !stream->idle) {
                return false;
            }
        }
        return true;
    });
}

DecodePool::Stats DecodePool::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    Stats st;
    for (const auto &[key, stream] : streams_) {
        StreamStats s = stream->published;
        s.idle = stream->idle;
        s.failed = stream->failed;
        s.target = stream->target.sourceTime;
        st.streams.push_back(std::move(s));
    }
    st.workerThreads = static_cast<int>(workers_.size());
    st.scrubRequests = scrubRequests_;
    st.scrubServiced = scrubServiced_;
    st.scrubCancelled = scrubCancelled_;
    st.scrubFailed = scrubFailed_;
    return st;
}

} // namespace ve::media
