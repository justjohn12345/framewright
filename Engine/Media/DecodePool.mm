#include "DecodePool.h"

#include "../Model/TimeUtil.h"

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
    uint64_t lastServed = 0;
    StreamStats published;
    /// Shared with the decoder (DecodeOptions::interrupt): setTargets() requests it when the
    /// work in flight became useless; the worker clears it before every step.
    const std::shared_ptr<DecodeInterrupt> interrupt = std::make_shared<DecodeInterrupt>();

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
    std::optional<MediaError> error;
};

struct DecodePool::ScrubDecoder {
    std::unique_ptr<IVideoDecoder> decoder;
    std::shared_ptr<AssetSlot> slot;
    std::shared_ptr<DecodeInterrupt> interrupt;
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
                                          stream->target.direction == DecodeDirection::Forward});
    }
    cache_->setFocus(focusClient_, std::move(focus));
}

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
                if (moved && stream->busy && !stream->failed && makesWorkInFlightUseless(*stream, t)) {
                    stream->interrupt->request();
                }
                stream->target = std::move(t);
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
    p.window = s.window;
    p.frameBytes = s.frameBytes;
    p.eof = s.eof;
    p.videoEnd = s.videoEnd;
    p.framesDecoded = s.framesDecoded;
    p.seeks = s.seeks;
    p.interrupts = s.interrupts;
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
        lock.unlock();

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
    return cache_->put(slot->epoch, s.key.asset, f, frameDuration, coverFrom);
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
    if (!s.decoder) {
        s.openFailed = false; // Recomputed by this attempt (a transient failure may be over).
        s.error.reset();
        auto routed = slot->resolve(*router_);
        if (!routed.ok()) {
            s.error = routed.error();
            s.openFailed = true;
            return StepResult::Settled;
        }
        const RoutedMediaInfo &info = *routed.value();
        DecodeOptions options = config_.decodeOptions;
        options.interrupt = s.interrupt;
        auto opened = router_->makeVideoDecoder(info, target.trackIndex, options);
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
        const TrackRoute *route = target.trackIndex < 0 ? info.visualRoute() : info.route(target.trackIndex);
        const TrackInfo *track = route ? info.info.track(route->trackIndex) : nullptr;
        s.frameDuration = track && track->kind == TrackKind::Still ? kCMTimeInvalid
                          : track && isPositive(track->frameDuration) ? track->frameDuration
                                                                      : s.decoder->frameDuration();
        s.trackEnd = track && track->kind != TrackKind::Still && isNumeric(track->duration)
                         ? (isNumeric(track->startTime) ? track->startTime : kCMTimeZero) + track->duration
                         : kCMTimeInvalid;
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
    // the last frame is searched for first: seek back 2 frames (at least 0.25 s) before where the
    // stream ended, doubling the step, and decode forward to the end.
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
        CMTime step = s.findingEnd && isPositive(s.tailStep) ? s.tailStep + s.tailStep : kCMTimeInvalid;
        if (!isNumeric(step)) {
            step = isPositive(s.frameDuration) ? s.frameDuration + s.frameDuration : kCMTimeZero;
            step = maxTime(step, CMTimeMake(1, 4));
        }
        const CMTime probe = clampToZero(from - step);
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
        return at < s.rangeEnd && !(isNumeric(s.repairedAt) && s.repairedAt == at) && !cache_->contains(asset, at);
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

// MARK: - Scrub

void DecodePool::requestFrame(AssetId asset, CMTime time, ScrubCallback callback, uint64_t lane) {
    if (!callback) {
        return;
    }
    bool accepted = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!stopping_) {
            accepted = true;
            ++scrubRequests_;
            const ScrubKey key{asset, lane};
            auto it = scrubPending_.find(key);
            if (it != scrubPending_.end()) {
                scrubToCancel_.push_back(std::move(it->second.callback));
                it->second = ScrubRequest{time, std::move(callback), ++scrubSequence_};
            } else {
                scrubPending_.emplace(key, ScrubRequest{time, std::move(callback), ++scrubSequence_});
            }
            if (scrubBusy_ && scrubInFlight_ == key && scrubInterrupt_) {
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
            Result<ScrubFrame> result = slot ? serviceScrub(key, slot, request.time)
                                             : Result<ScrubFrame>(makeError(MediaErrorCode::InvalidArgument,
                                                                            "requestFrame: unknown asset (no path)"));
            ok = result.ok();
            cancelled = !ok && result.error().code == MediaErrorCode::Cancelled;
            request.callback(cancelled ? Result<ScrubFrame>(cancelledError()) : std::move(result));
            request.callback = nullptr;
        }

        lock.lock();
        scrubBusy_ = false;
        scrubInterrupt_.reset();
        ++(ok ? scrubServiced_ : cancelled ? scrubCancelled_ : scrubFailed_);
        progressCv_.notify_all();
    }
    lock.unlock();
    scrubDecoders_.clear();
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

    if (auto cached = cache_->get(key.asset, track->kind == TrackKind::Still ? kCMTimeZero : time)) {
        return ScrubFrame{cached->image, cached->pts, cached->duration, cached->index, true};
    }

    // The interrupt the scrub thread armed for this request (requestFrame() requests it when a
    // newer request for the same key arrives).
    std::shared_ptr<DecodeInterrupt> interrupt;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        interrupt = scrubInterrupt_;
    }
    auto &entry = scrubDecoders_[key];
    if (!entry || entry->slot != slot) {
        entry.reset();
        DecodeOptions options = config_.decodeOptions;
        options.interrupt = interrupt;
        auto opened = router_->makeVideoDecoder(info, route->trackIndex, options);
        if (!opened.ok()) {
            scrubDecoders_.erase(key);
            return std::move(opened).error();
        }
        entry = std::make_unique<ScrubDecoder>();
        entry->decoder = std::move(opened.value().decoder);
        entry->slot = slot;
        entry->interrupt = interrupt;
        while (scrubDecoders_.size() > static_cast<size_t>(config_.maxScrubDecoders)) {
            // Least recently used, never the one just opened.
            auto age = [&](const auto &e) { return e.first == key ? UINT64_MAX : e.second->lastUse; };
            auto lru = std::min_element(scrubDecoders_.begin(), scrubDecoders_.end(),
                                        [&](const auto &a, const auto &b) { return age(a) < age(b); });
            scrubDecoders_.erase(lru);
        }
    }
    ScrubDecoder &d = *scrubDecoders_.at(key);
    d.lastUse = ++scrubUseCounter_;

    auto decodeAt = [&](CMTime at) -> Result<std::optional<VideoFrame>> {
        Status st = d.decoder->seek(at);
        if (!st.ok()) {
            return std::move(st).error();
        }
        return d.decoder->next();
    };
    // Past the end: the last frame, as a scrub to the end of a clip expects. It is found like the
    // streams find it (step()): seek back from the track's end (or `time`) by 2 frames (at least
    // 0.25 s), doubling the step until a frame comes out, and decode forward to the end.
    auto lastFrame = [&](CMTime from) -> Result<std::optional<VideoFrame>> {
        CMTime step = maxTime(isPositive(fd) ? fd + fd : kCMTimeZero, CMTimeMake(1, 4));
        for (;;) {
            const CMTime probe = clampToZero(from - step);
            if (Status st = d.decoder->seek(probe); !st.ok()) {
                return std::move(st).error();
            }
            std::optional<VideoFrame> last;
            for (;;) {
                auto n = d.decoder->next();
                if (!n.ok()) {
                    return std::move(n).error();
                }
                if (!n.value()) {
                    break;
                }
                last = std::move(n).value();
            }
            if (last || !(probe > kCMTimeZero)) {
                return last;
            }
            from = probe;
            step = step + step;
        }
    };
    auto frame = decodeAt(time);
    bool pastEnd = false;
    if (frame.ok() && !frame.value() && track->kind != TrackKind::Still) {
        CMTime from = time;
        if (isNumeric(track->duration)) {
            from = minTime(from, (isNumeric(track->startTime) ? track->startTime : kCMTimeZero) + track->duration);
        }
        frame = lastFrame(from);
        pastEnd = true;
    }
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    if (!frame.value()) {
        return makeError(MediaErrorCode::InvalidArgument, "no frame at or after the requested time in " + slot->url);
    }
    const VideoFrame &f = *frame.value();
    {
        // Checked and put under mutex_ (see publishStreamFrame): a frame of a file the asset no
        // longer names is neither cached nor delivered.
        std::lock_guard<std::mutex> lock(mutex_);
        if (slot->retired || slot->epoch != epoch_) {
            return cancelledError();
        }
        if (pastEnd) {
            // The last frame holds for every later time (as the streams hold it at the end).
            VideoFrame held = f;
            held.duration = kCMTimePositiveInfinity;
            cache_->put(slot->epoch, key.asset, held, fd, held.pts);
        } else {
            cache_->put(slot->epoch, key.asset, f, fd, time < f.pts ? time : f.pts);
        }
    }
    return ScrubFrame{f.image, f.pts, f.duration, FrameCache::frameIndex(f.pts, fd), false};
}

// MARK: - Observation

bool DecodePool::waitUntilIdle(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return progressCv_.wait_for(lock, timeout, [&] {
        if (!scrubPending_.empty() || !scrubToCancel_.empty() || scrubBusy_ || !retired_.empty() || retiring_ > 0 ||
            stepsInFlight_ > 0 || scrubCleanupPending_) {
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
            stream->repairedAt = kCMTimeInvalid; // re-arm the repair of an evicted playhead frame
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
