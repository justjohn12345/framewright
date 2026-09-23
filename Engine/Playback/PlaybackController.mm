#include "PlaybackController.h"

#include "../Render/Scheduler.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace ve::playback {

using audio::ClockMode;
using media::FrameCache;

const char *nameOf(PlaybackState state) {
    switch (state) {
    case PlaybackState::Stopped:
        return "stopped";
    case PlaybackState::Prerolling:
        return "prerolling";
    case PlaybackState::Playing:
        return "playing";
    case PlaybackState::Scrubbing:
        return "scrubbing";
    }
    return "?";
}

std::string mediaPathForURL(const std::string &url) {
    if (url.rfind("file://", 0) == 0) {
        @autoreleasepool {
            NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
            if (u.isFileURL && u.path) {
                return std::string(u.path.fileSystemRepresentation);
            }
        }
    }
    return url;
}

int64_t frameSlotFor(const VideoLayer &layer, const MediaAsset &asset) {
    return asset.isStill() ? 0 : FrameCache::frameIndex(layer.sourceTime, asset.frameDuration);
}

namespace {

/// Media paths are absolute POSIX paths; the model may hold file URLs.
std::string mediaPath(const std::string &url) {
    return mediaPathForURL(url);
}

CMTime lastFrameStartOf(const Sequence &sequence) {
    const CMTime duration = sequence.duration();
    if (!(duration > kCMTimeZero) || !isPositive(sequence.frameDuration)) {
        return kCMTimeZero;
    }
    const int64_t frames = frameIndexAt(duration, sequence.frameDuration, SnapMode::Ceil);
    return timeForFrame(std::max<int64_t>(0, frames - 1), sequence.frameDuration);
}

int64_t slotFor(const VideoLayer &layer, const MediaAsset &asset) {
    return frameSlotFor(layer, asset);
}

double absRate(double rate) {
    return std::fabs(rate);
}

} // namespace

// MARK: - Shared core (control side + frame source)

struct PlaybackController::Core {
    Core(std::shared_ptr<audio::HostClock> host, double sampleRate, std::shared_ptr<FrameCache> frameCache)
        : clock(std::move(host), sampleRate), cache(std::move(frameCache)) {}

    struct Display {
        int64_t value = 0;
        int32_t timescale = 1;
        bool clockDriven = false;
        double rate = 1.0;
    };

    /// Render-thread state of one frame source.
    struct RenderState {
        std::shared_ptr<const Project> project;
        SequenceId sequenceId;
        uint64_t snapshotVersion = 0;
        uint64_t sequenceGeneration = 0; // of the pictures held below

        bool hasFrame = false;
        int64_t lastFrame = -1;
        uint64_t lastSnapshotVersion = 0;
        uint64_t lastFrameVersion = 0;
        bool lastComplete = false;
        bool lastClockDriven = false;
        uint32_t lastEpoch = 0; // clock epoch of the last presentation (a seek starts a new one)
        uint64_t lastPresentNanos = 0;
        // Monotonic guard on the clock reads of one epoch (target timestamps can be jittered).
        uint32_t guardEpoch = 0;
        CMTime guardTime = kCMTimeInvalid;
        std::vector<ClipId> lastClips;
        std::vector<render::TextureSet> lastTextures;
        std::vector<int64_t> lastShown;
        std::vector<FrameCache::PinnedFrame> pins; // index-aligned with lastClips

        std::vector<ClipId> nextClips;
        std::vector<int64_t> nextShown;
        std::vector<FrameCache::PinnedFrame> nextPins;
        std::vector<render::TextureSet> nextTextures;
        std::vector<size_t> nextMissing; // layers of the next frame without their exact picture
        PresentedFrame info;
    };

    audio::Clock clock;
    const std::shared_ptr<FrameCache> cache;

    std::mutex snapshotMutex; // held only to copy/replace the pointer
    std::shared_ptr<const Project> project;
    SequenceId sequenceId;
    uint64_t sequenceGeneration = 0; // snapshotMutex; bumped by setSequence (another sequence)
    std::atomic<uint64_t> snapshotVersion{1};

    audio::SeqLock<Display> display;
    std::atomic<uint64_t> frameVersion{0};

    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<uint64_t> late{0};
    std::atomic<uint64_t> hits{0};
    std::atomic<uint64_t> misses{0};
    std::atomic<uint64_t> mapFailures{0};
    std::atomic<uint64_t> monotonicHolds{0};
    std::atomic<double> fps{0.0};
    std::atomic<uint64_t> lastClockPresentNanos{0}; // host time of the last clock-driven presentation

    mutable std::mutex presentedMutex;
    PresentedFrame presentedInfo;

    // Scrub requests for the paused/scrubbed picture (requestDisplayFramesLocked). While a
    // request of the current display is in flight, the frame source keeps presenting the
    // previous complete picture rather than a frame with a layer drawn without its picture.
    // Held only for a few integer operations (the render thread takes it too).
    std::mutex displayRequestMutex;
    uint64_t displayRequestGeneration = 0; // displayRequestMutex
    int displayRequestsInFlight = 0;       // displayRequestMutex

    /// A new display target: forgets the previous target's requests (they no longer hold the
    /// picture). Returns the generation to tag this target's requests with.
    uint64_t beginDisplayRequests() {
        std::lock_guard<std::mutex> lock(displayRequestMutex);
        displayRequestsInFlight = 0;
        return ++displayRequestGeneration;
    }
    /// Called before each request of `generation` is issued (so its completion never precedes it).
    void displayRequestIssued(uint64_t generation) {
        std::lock_guard<std::mutex> lock(displayRequestMutex);
        if (generation == displayRequestGeneration) {
            ++displayRequestsInFlight;
        }
    }
    /// A request of `generation` completed (with a frame, an error or Cancelled). Returns
    /// whether it belonged to the current display target.
    bool displayRequestDone(uint64_t generation) {
        std::lock_guard<std::mutex> lock(displayRequestMutex);
        if (generation != displayRequestGeneration) {
            return false;
        }
        if (displayRequestsInFlight > 0) {
            --displayRequestsInFlight;
        }
        return true;
    }
    bool displayRequestsPending() {
        std::lock_guard<std::mutex> lock(displayRequestMutex);
        return displayRequestsInFlight > 0;
    }

    /// `newSequence`: another sequence (or project) replaces the old one, whose clip ids may be
    /// reused: the frame sources drop the pictures they hold instead of showing them for clips
    /// of the new sequence with the same id.
    void setSnapshot(std::shared_ptr<const Project> p, SequenceId id, bool newSequence) {
        {
            std::lock_guard<std::mutex> lock(snapshotMutex);
            project = std::move(p);
            sequenceId = id;
            if (newSequence) {
                ++sequenceGeneration;
            }
        }
        snapshotVersion.fetch_add(1, std::memory_order_acq_rel);
    }

    void resetFps() {
        fps.store(0.0, std::memory_order_relaxed);
        lastClockPresentNanos.store(0, std::memory_order_relaxed);
    }

    bool renderFrame(RenderState &rs, const render::PreviewFrameRequest &request, render::PreviewFrame &frame);
};

bool PlaybackController::Core::renderFrame(RenderState &rs, const render::PreviewFrameRequest &request,
                                           render::PreviewFrame &frame) {
    const uint64_t version = snapshotVersion.load(std::memory_order_acquire);
    if (version != rs.snapshotVersion) {
        std::shared_ptr<const Project> previous;
        uint64_t generation = 0;
        {
            std::lock_guard<std::mutex> lock(snapshotMutex);
            previous = std::move(rs.project);
            rs.project = project;
            rs.sequenceId = sequenceId;
            generation = sequenceGeneration;
        }
        rs.snapshotVersion = version;
        if (generation != rs.sequenceGeneration) {
            // Another sequence: nothing held belongs to it (clip ids restart per project).
            rs.sequenceGeneration = generation;
            rs.pins.clear();
            rs.lastClips.clear();
            rs.lastTextures.clear();
            rs.lastShown.clear();
            rs.hasFrame = false;
        }
    }
    const Sequence *sequence = rs.project ? rs.project->findSequence(rs.sequenceId) : nullptr;
    if (!sequence || !isPositive(sequence->frameDuration)) {
        if (!rs.hasFrame) {
            return false;
        }
        frame.graph = RenderGraph{};
        frame.textures.clear();
        frame.status = media::okStatus();
        rs.pins.clear();
        rs.lastClips.clear();
        rs.lastTextures.clear();
        rs.lastShown.clear();
        rs.hasFrame = false;
        return true;
    }

    const Display d = display.load();
    const uint32_t epoch = clock.epoch();
    CMTime t;
    if (d.clockDriven) {
        // The time the frame will be on screen (the display link's target), in the clock's
        // host time base; "now" for callers without one.
        t = request.targetTimestamp > 0 ? clock.timeAt(audio::HostClock::secondsToNanos(request.targetTimestamp))
                                        : clock.now();
        // Never step backwards within one run of the clock (forwards when playing in reverse):
        // a late audio callback or a jittered target must not show frame N after N + 1.
        if (rs.guardEpoch == epoch && isNumeric(rs.guardTime)) {
            const bool behind = d.rate >= 0 ? t < rs.guardTime : t > rs.guardTime;
            if (behind) {
                t = rs.guardTime;
                monotonicHolds.fetch_add(1, std::memory_order_relaxed);
            }
        }
        rs.guardEpoch = epoch;
        rs.guardTime = t;
    } else {
        t = CMTimeMake(d.value, d.timescale);
    }
    const CMTime fd = sequence->frameDuration;
    const int64_t lastIndex = frameIndexAt(lastFrameStartOf(*sequence), fd, SnapMode::Floor);
    const int64_t index = std::clamp<int64_t>(frameIndexAt(t, fd, SnapMode::Floor), 0, lastIndex);
    const uint64_t frameVer = frameVersion.load(std::memory_order_acquire);
    if (rs.hasFrame && index == rs.lastFrame && version == rs.lastSnapshotVersion && frameVer == rs.lastFrameVersion &&
        rs.lastComplete) {
        return false;
    }

    RenderGraph graph = Scheduler::renderGraphAt(*sequence, *rs.project, timeForFrame(index, fd));
    const size_t n = graph.layers.size();
    // A fresh frame: its status reports only this frame's problems (the view clears lastError
    // with the first frame whose status is ok).
    media::Status status = media::okStatus();
    // Built aside: `frame` (the view's current picture) is only replaced once this frame is
    // presented, so holding the previous picture below leaves it intact.
    rs.nextTextures.assign(n, render::TextureSet{});
    rs.nextClips.clear();
    rs.nextShown.clear();
    rs.nextPins.clear();
    rs.nextMissing.clear();
    rs.info.layers.clear();
    for (size_t i = 0; i < n; ++i) {
        const VideoLayer &layer = graph.layers[i];
        PresentedLayer shown;
        shown.clip = layer.clipId;
        shown.asset = layer.assetId;
        FrameCache::PinnedFrame pin;
        int64_t shownIndex = -1;
        if (const MediaAsset *asset = rs.project->findAsset(layer.assetId)) {
            const int64_t slot = slotFor(layer, *asset);
            shown.wantedIndex = slot;
            pin = cache->acquire(layer.assetId, slot);
            bool usable = static_cast<bool>(pin);
            if (usable && request.textureCache) {
                auto mapped = request.textureCache->textures(pin.image());
                if (mapped.ok()) {
                    rs.nextTextures[i] = std::move(mapped).value();
                } else {
                    // Decoded but not drawable: neither a hit nor exact; keep the old picture.
                    mapFailures.fetch_add(1, std::memory_order_relaxed);
                    usable = false;
                    if (status.ok()) {
                        status = std::move(mapped).error();
                    }
                }
            }
            if (usable) {
                hits.fetch_add(1, std::memory_order_relaxed);
                shownIndex = pin.frame().index;
                shown.exact = true;
            } else {
                if (!pin) {
                    misses.fetch_add(1, std::memory_order_relaxed);
                }
                pin = FrameCache::PinnedFrame{};
                rs.nextMissing.push_back(i);
            }
        }
        shown.shownIndex = shownIndex;
        rs.nextClips.push_back(layer.clipId);
        rs.nextShown.push_back(shownIndex);
        rs.nextPins.push_back(std::move(pin));
        rs.info.layers.push_back(shown);
    }
    const bool complete = rs.nextMissing.empty();

    if (!complete && !d.clockDriven && rs.hasFrame && rs.lastComplete && displayRequestsPending()) {
        // Paused, stepping or scrubbing, and a picture of this frame is still being decoded:
        // keep the previous complete picture on screen (unchanged) instead of presenting this
        // frame with a layer missing; the request's completion asks for a redraw. The pins taken
        // above are released; the previous frame's stay.
        rs.nextPins.clear();
        rs.nextTextures.clear();
        if (presentedMutex.try_lock()) { // diagnostics only: never wait for a reader
            presentedInfo.heldBackFrameIndex = index;
            presentedMutex.unlock();
        }
        return false;
    }
    for (size_t i : rs.nextMissing) {
        // Keep the clip's previous picture up until its frame lands.
        const ClipId clip = graph.layers[i].clipId;
        for (size_t j = 0; j < rs.lastClips.size(); ++j) {
            if (rs.lastClips[j] == clip) {
                rs.nextTextures[i] = rs.lastTextures[j];
                rs.nextPins[i] = std::move(rs.pins[j]);
                rs.nextShown[i] = rs.lastShown[j];
                rs.info.layers[i].shownIndex = rs.lastShown[j];
                rs.lastClips[j] = ClipId{};
                break;
            }
        }
    }
    frame.textures.assign(rs.nextTextures.begin(), rs.nextTextures.end());

    const uint64_t nowNanos = clock.hostClock()->nowNanos();
    if (d.clockDriven) {
        if (!complete) {
            late.fetch_add(1, std::memory_order_relaxed);
        }
        // Drops are only counted within one run of the clock: a seek or rate change is a jump.
        if (rs.hasFrame && rs.lastClockDriven && rs.lastEpoch == epoch && rs.lastPresentNanos > 0 &&
            nowNanos > rs.lastPresentNanos) {
            const double dt = static_cast<double>(nowNanos - rs.lastPresentNanos) * 1e-9;
            const int64_t step = std::llabs(index - rs.lastFrame);
            const auto expected = static_cast<int64_t>(std::ceil(absRate(d.rate) * dt / CMTimeGetSeconds(fd) - 1e-6));
            if (step > std::max<int64_t>(1, expected)) {
                dropped.fetch_add(static_cast<uint64_t>(step - std::max<int64_t>(1, expected)),
                                  std::memory_order_relaxed);
            }
            const double instant = 1.0 / dt;
            const double previousFps = fps.load(std::memory_order_relaxed);
            fps.store(previousFps <= 0 ? instant : previousFps * 0.9 + instant * 0.1, std::memory_order_relaxed);
        }
        lastClockPresentNanos.store(nowNanos, std::memory_order_relaxed);
    }

    frame.graph = std::move(graph);
    frame.status = std::move(status);
    // Swap in the new pins; the previous frame's pins are released here, after the new ones
    // were taken (so a frame shown twice is never unpinned in between).
    std::swap(rs.pins, rs.nextPins);
    std::swap(rs.lastClips, rs.nextClips);
    std::swap(rs.lastShown, rs.nextShown);
    rs.nextPins.clear();
    rs.lastTextures.assign(frame.textures.begin(), frame.textures.end());
    rs.hasFrame = true;
    rs.lastFrame = index;
    rs.lastSnapshotVersion = version;
    rs.lastFrameVersion = frameVer;
    rs.lastComplete = complete;
    rs.lastClockDriven = d.clockDriven;
    rs.lastEpoch = epoch;
    rs.lastPresentNanos = nowNanos;
    const uint64_t serial = presented.fetch_add(1, std::memory_order_relaxed) + 1;

    rs.info.serial = serial;
    rs.info.time = t;
    rs.info.frameIndex = index;
    rs.info.clockDriven = d.clockDriven;
    rs.info.heldBackFrameIndex = -1;
    if (presentedMutex.try_lock()) { // diagnostics only: never wait for a reader
        std::swap(presentedInfo, rs.info);
        presentedMutex.unlock();
    }
    return true;
}

// MARK: - Observer hub

struct PlaybackController::ObserverHub : std::enable_shared_from_this<ObserverHub> {
    std::mutex mutex;
    dispatch_queue_t queue = nil;
    PlaybackObserver observer;
    PlaybackStatus latest;
    bool statusPending = false;
    bool displayPending = false;

    void postStatus(const PlaybackStatus &status) {
        std::lock_guard<std::mutex> lock(mutex);
        latest = status;
        if (!queue || !observer.statusChanged || statusPending) {
            return;
        }
        statusPending = true;
        std::shared_ptr<ObserverHub> self = shared_from_this();
        dispatch_async(queue, ^{
          PlaybackStatus current;
          std::function<void(const PlaybackStatus &)> callback;
          {
              std::lock_guard<std::mutex> inner(self->mutex);
              self->statusPending = false;
              current = self->latest;
              callback = self->observer.statusChanged;
          }
          if (callback) {
              callback(current);
          }
        });
    }

    void postNeedsDisplay() {
        std::lock_guard<std::mutex> lock(mutex);
        if (!queue || !observer.needsDisplay || displayPending) {
            return;
        }
        displayPending = true;
        std::shared_ptr<ObserverHub> self = shared_from_this();
        dispatch_async(queue, ^{
          std::function<void()> callback;
          {
              std::lock_guard<std::mutex> inner(self->mutex);
              self->displayPending = false;
              callback = self->observer.needsDisplay;
          }
          if (callback) {
              callback();
          }
        });
    }
};

// MARK: - Controller

PlaybackController::PlaybackController(std::shared_ptr<media::BackendRouter> router,
                                       std::shared_ptr<FrameCache> cache, std::shared_ptr<media::DecodePool> pool,
                                       PlaybackConfig config)
    : router_(std::move(router)), cache_(std::move(cache)), pool_(std::move(pool)), config_(std::move(config)) {
    core_ = std::make_shared<Core>(config_.hostClock ? config_.hostClock : audio::HostClock::system(),
                                   config_.mixer.sampleRate, cache_);
    hub_ = std::make_shared<ObserverHub>();
    mixer_ = std::make_unique<audio::AudioMixer>(router_, &core_->clock, config_.mixer);
    if (config_.makeOutput) {
        output_ = config_.makeOutput(*mixer_);
    }
    if (!output_) {
        output_ = std::make_unique<audio::AutomaticAudioOutput>(*mixer_);
    }
    // Events arrive on an output thread: queue them for the tick thread, which applies them
    // under mutex_ (the Clock has a single control writer).
    output_->setEventHandler([this](const audio::AudioOutputEvent &event) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            outputEvents_.push_back(event);
        }
        tickCv_.notify_all();
    });
    publishDisplayLocked();
    tickThread_ = std::thread([this] { tickMain(); });
}

PlaybackController::~PlaybackController() {
    output_->setEventHandler({}); // waits for an event handler in flight (it takes mutex_)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopTick_ = true;
    }
    tickCv_.notify_all();
    if (tickThread_.joinable()) {
        tickThread_.join();
    }
    output_->stop();
    output_.reset();
    mixer_.reset();
    {
        std::lock_guard<std::mutex> lock(hub_->mutex);
        hub_->observer = PlaybackObserver{};
        hub_->queue = nil;
    }
}

audio::Clock &PlaybackController::clock() {
    return core_->clock;
}

// MARK: Helpers (mutex_ held)

const Sequence *PlaybackController::sequenceLocked() const {
    return project_ ? project_->findSequence(sequenceId_) : nullptr;
}

CMTime PlaybackController::lastFrameStartLocked() const {
    const Sequence *sequence = sequenceLocked();
    return sequence ? lastFrameStartOf(*sequence) : kCMTimeZero;
}

CMTime PlaybackController::clampLocked(CMTime t) const {
    const Sequence *sequence = sequenceLocked();
    if (!sequence || !isNumeric(t) || !isPositive(sequence->frameDuration)) {
        return kCMTimeZero;
    }
    const CMTime snapped = snapToFrame(t, sequence->frameDuration, SnapMode::Floor);
    return clampTime(snapped, kCMTimeZero, lastFrameStartOf(*sequence));
}

CMTime PlaybackController::nowLocked() const {
    if (state_ == PlaybackState::Playing) {
        return clampLocked(core_->clock.now());
    }
    return displayTime_;
}

PlaybackStatus PlaybackController::statusLocked() const {
    PlaybackStatus status;
    status.time = nowLocked();
    status.state = state_;
    status.rate = rate_;
    status.audioActive = audioActive_;
    status.lastError = lastError_;
    return status;
}

void PlaybackController::publishDisplayLocked() {
    Core::Display d;
    d.value = displayTime_.value;
    d.timescale = displayTime_.timescale > 0 ? displayTime_.timescale : 1;
    d.clockDriven = state_ == PlaybackState::Playing;
    d.rate = rate_;
    core_->display.store(d);
}

void PlaybackController::postStatusLocked() {
    const PlaybackStatus status = statusLocked();
    if (const Sequence *sequence = sequenceLocked(); sequence && isPositive(sequence->frameDuration)) {
        lastPostedFrame_ = frameIndexAt(status.time, sequence->frameDuration, SnapMode::Floor);
    }
    hub_->postStatus(status);
}

void PlaybackController::postNeedsDisplay() {
    hub_->postNeedsDisplay();
}

void PlaybackController::touchIdleLocked() {
    idleDeadline_ = std::chrono::steady_clock::now() + config_.outputIdleTimeout;
}

double PlaybackController::audioLatencyLocked(double rate) const {
    return output_->outputLatency() + mixer_->processingLatency(static_cast<int>(rate));
}

void PlaybackController::registerAssetsLocked() {
    if (!project_) {
        return;
    }
    for (const MediaAsset &asset : project_->assets) {
        const std::string path = mediaPath(asset.url);
        auto known = registeredPaths_.find(asset.id);
        if (known != registeredPaths_.end() && known->second == path) {
            continue;
        }
        registeredPaths_[asset.id] = path;
        std::optional<media::RoutedMediaInfo> routed;
        if (auto r = routing_.find(asset.id); r != routing_.end()) {
            routed = r->second;
        }
        if (pool_) {
            pool_->registerAsset(asset.id, path, routed);
        }
        mixer_->registerAsset(asset.id, path, routed);
    }
}

void PlaybackController::retargetLocked(CMTime at, double rate) {
    lastRetarget_ = at;
    const Sequence *sequence = sequenceLocked();
    if (!pool_ || !sequence || !isPositive(sequence->frameDuration)) {
        return;
    }
    const bool backward = rate < 0;
    const double speed = std::clamp(absRate(rate), 1.0, 8.0);
    pool_->setLookahead(CMTimeMultiplyByFloat64(config_.decodeLookahead, std::min(speed, 4.0)));
    const CMTime fd = sequence->frameDuration;
    const int64_t start = frameIndexAt(at, fd, SnapMode::Floor);
    const int64_t span = std::max<int64_t>(
        1, static_cast<int64_t>(std::ceil(CMTimeGetSeconds(config_.decodeLookahead) * speed / CMTimeGetSeconds(fd))));
    const int64_t stride = std::max<int64_t>(1, static_cast<int64_t>(speed));
    const int64_t lastIndex = frameIndexAt(lastFrameStartOf(*sequence), fd, SnapMode::Floor);

    std::vector<media::DecodeTarget> targets;
    std::vector<ClipId> seen;
    for (int64_t k = 0; k <= span; k += stride) {
        const int64_t index = backward ? start - k : start + k;
        if (index < 0 || index > lastIndex) {
            break;
        }
        const RenderGraph graph = Scheduler::renderGraphAt(*sequence, *project_, timeForFrame(index, fd));
        for (size_t i = 0; i < graph.layers.size(); ++i) {
            const VideoLayer &layer = graph.layers[i];
            if (std::find(seen.begin(), seen.end(), layer.clipId) != seen.end()) {
                continue;
            }
            seen.push_back(layer.clipId);
            media::DecodeTarget target;
            target.asset = layer.assetId;
            target.trackIndex = -1;
            target.sourceTime = layer.sourceTime;
            target.direction = backward ? media::DecodeDirection::Backward : media::DecodeDirection::Forward;
            // Visible now first (upper layers first), then by proximity.
            target.priority = static_cast<int>(10000 - k * 10 + static_cast<int64_t>(i));
            target.lane = layer.clipId.value();
            targets.push_back(std::move(target));
        }
    }
    pool_->setTargets(std::move(targets));
}

void PlaybackController::planAudioLocked(CMTime at) {
    audioPlannedAt_ = at;
    replanAudio_ = false;
    const Sequence *sequence = sequenceLocked();
    if (!sequence) {
        mixer_->clearGraph();
        return;
    }
    const CMTime from = maxTime(kCMTimeZero, at - CMTimeMake(1, 10));
    const CMTime to = at + CMTimeMakeWithSeconds(config_.audioHorizonSeconds * std::max(1.0, absRate(rate_)),
                                                 kPreciseTimescale);
    AudioGraph graph = Scheduler::audioGraphFor(*sequence, *project_, TimeRange{from, to});
    // Clips whose asset has no audio track contribute nothing.
    graph.segments.erase(std::remove_if(graph.segments.begin(), graph.segments.end(),
                                        [&](const AudioSegment &segment) {
                                            const MediaAsset *asset = project_->findAsset(segment.assetId);
                                            return !asset || !asset->hasAudio();
                                        }),
                         graph.segments.end());
    mixer_->setGraph(graph, at);
}

void PlaybackController::requestDisplayFramesLocked(CMTime at) {
    const Sequence *sequence = sequenceLocked();
    if (!pool_ || !sequence) {
        return;
    }
    const RenderGraph graph = Scheduler::renderGraphAt(*sequence, *project_, at);
    std::weak_ptr<Core> weakCore = core_;
    std::weak_ptr<ObserverHub> weakHub = hub_;
    const uint64_t generation = core_->beginDisplayRequests();
    for (size_t i = 0; i < graph.layers.size(); ++i) {
        const VideoLayer &layer = graph.layers[i];
        const MediaAsset *asset = project_->findAsset(layer.assetId);
        if (!asset || cache_->contains(layer.assetId, slotFor(layer, *asset))) {
            continue;
        }
        const uint64_t lane = config_.scrubLaneBase + i;
        core_->displayRequestIssued(generation);
        pool_->requestFrame(layer.assetId, layer.sourceTime,
                            [weakCore, weakHub, generation](media::Result<media::ScrubFrame> r) {
                                auto core = weakCore.lock();
                                if (!core) {
                                    return;
                                }
                                const bool current = core->displayRequestDone(generation);
                                if (!r.ok() && !current) {
                                    return; // superseded by a newer display target
                                }
                                // A picture landed, or the current target's request ended
                                // without one (failed or cancelled): either way the frame source
                                // re-evaluates (and stops holding the previous picture).
                                core->frameVersion.fetch_add(1, std::memory_order_acq_rel);
                                if (auto hub = weakHub.lock()) {
                                    hub->postNeedsDisplay();
                                }
                            },
                            lane);
    }
    postNeedsDisplay();
}

bool PlaybackController::firstFramesReadyLocked(CMTime at) const {
    const Sequence *sequence = sequenceLocked();
    if (!sequence) {
        return true;
    }
    const RenderGraph graph = Scheduler::renderGraphAt(*sequence, *project_, at);
    return std::all_of(graph.layers.begin(), graph.layers.end(), [&](const VideoLayer &layer) {
        const MediaAsset *asset = project_->findAsset(layer.assetId);
        return !asset || cache_->contains(layer.assetId, slotFor(layer, *asset));
    });
}

// MARK: Transport internals (mutex_ held)

void PlaybackController::beginPrerollLocked(CMTime at, double rate) {
    const Sequence *sequence = sequenceLocked();
    if (!sequence || !(sequence->duration() > kCMTimeZero)) {
        return;
    }
    const CMTime last = lastFrameStartOf(*sequence);
    at = clampLocked(at);
    if (rate > 0 && at >= last) {
        at = kCMTimeZero;
    } else if (rate < 0 && at <= kCMTimeZero) {
        at = last;
    }
    const auto now = std::chrono::steady_clock::now();
    core_->clock.setTime(at);
    if (mixer_->isRunning()) {
        lastStopSerial_ = mixer_->stop(); // fades out; the tick thread waits for it before repositioning
        lastStopAt_ = now;
    }
    audioActive_ = false;
    join_ = Join{};
    rate_ = rate;
    displayTime_ = at;
    state_ = PlaybackState::Prerolling;
    audioWarm_ = false;
    preroll_ = Preroll{};
    preroll_.serial = ++prerollSerial_;
    preroll_.at = at;
    preroll_.rate = rate;
    preroll_.wantAudio = wantsAudio(rate);
    preroll_.stopSerial = lastStopSerial_;
    preroll_.stopRequested = lastStopAt_;
    outputFailed_ = false; // try the output again
    core_->resetFps();
    touchIdleLocked();
    publishDisplayLocked();
    requestDisplayFramesLocked(at); // the target picture while pre-rolling
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::advancePrerollLocked() {
    Preroll &p = preroll_;
    const auto now = std::chrono::steady_clock::now();
    if (!p.retargeted) {
        retargetLocked(p.at, p.rate);
        p.retargeted = true;
    }
    if (!p.planned) {
        // Repositioning the sources while the previous run is still fading out would cut the
        // fade short (a click): wait for the render thread (it needs one callback).
        const bool faded = !outputStarted_ || mixer_->stopCompleted(p.stopSerial) ||
                           now - p.stopRequested >= config_.stopFadeTimeout;
        if (!faded) {
            return;
        }
        if (p.wantAudio) {
            planAudioLocked(p.at);
            mixer_->prepare(p.at);
        }
        p.planned = true;
    }
    if (p.wantAudio && !outputStarted_ && !outputFailed_) {
        return; // manageOutput() is starting it
    }
    if (!p.waiting) {
        p.waiting = true;
        p.deadline = now + config_.prerollTimeout;
    }
    const bool videoReady = firstFramesReadyLocked(p.at);
    const bool audioReady = !p.wantAudio || outputFailed_ || mixer_->isPrimed(p.at);
    if ((videoReady && audioReady) || now >= p.deadline) {
        completePrerollLocked();
    }
}

void PlaybackController::completePrerollLocked() {
    const Preroll p = preroll_;
    audioActive_ = false;
    if (p.wantAudio && outputStarted_ && !outputFailed_) {
        core_->clock.setOutputLatency(audioLatencyLocked(p.rate));
        const uint32_t epoch = core_->clock.start(p.at, p.rate, ClockMode::AudioSamples);
        mixer_->start(p.at, static_cast<int>(p.rate), epoch);
        audioActive_ = true;
        lastError_.reset();
    } else {
        core_->clock.start(p.at, p.rate, ClockMode::HostTime);
    }
    state_ = PlaybackState::Playing;
    lastRetarget_ = p.at;
    publishDisplayLocked();
    postStatusLocked();
}

void PlaybackController::dropAudioLocked() {
    const CMTime t = core_->clock.now();
    core_->clock.start(t, rate_, ClockMode::HostTime);
    lastStopSerial_ = mixer_->stop();
    lastStopAt_ = std::chrono::steady_clock::now();
    audioActive_ = false;
    join_ = Join{};
}

void PlaybackController::noteDisplayChangedLocked() {
    displayChangedAt_ = std::chrono::steady_clock::now();
    audioWarm_ = false;
}

void PlaybackController::warmAudioLocked() {
    if (state_ != PlaybackState::Stopped || audioWarm_ || !sequenceLocked()) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now < displayChangedAt_ + config_.audioWarmDelay) {
        return;
    }
    const bool faded =
        !outputStarted_ || mixer_->stopCompleted(lastStopSerial_) || now - lastStopAt_ >= config_.stopFadeTimeout;
    if (!faded) {
        return;
    }
    planAudioLocked(displayTime_); // stopped: every source goes to where playback from here needs it
    mixer_->prepare(displayTime_);
    audioWarm_ = true;
}

void PlaybackController::advanceJoinLocked(CMTime t) {
    const Sequence *sequence = sequenceLocked();
    if (!sequence) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (!join_.active) {
        // Wait for the fade of the run that dropped the audio before repositioning sources.
        if (outputStarted_ && !mixer_->stopCompleted(lastStopSerial_) && now - lastStopAt_ < config_.stopFadeTimeout) {
            return;
        }
        const CMTime lead = CMTimeMakeWithSeconds(config_.audioJoinLeadSeconds * rate_, kPreciseTimescale);
        const CMTime at = snapToFrame(t + lead, sequence->frameDuration, SnapMode::Ceil);
        if (at >= sequence->duration()) {
            return; // too close to the end to bother
        }
        planAudioLocked(at);
        mixer_->prepare(at);
        join_.active = true;
        join_.at = at;
        return;
    }
    if (t > join_.at) {
        join_ = Join{}; // missed it (slow decode): prime a new point on the next tick
        return;
    }
    if (!mixer_->isPrimed(join_.at)) {
        return;
    }
    // Start once the first sample rendered at join_.at would become audible about when the
    // clock gets there: the output latency plus a couple of IO cycles ahead of it.
    const double latency = audioLatencyLocked(rate_);
    const CMTime lead = CMTimeMakeWithSeconds(rate_ * (latency + 0.025), kPreciseTimescale);
    if (t < join_.at - lead) {
        return;
    }
    core_->clock.setOutputLatency(latency);
    const uint32_t epoch = core_->clock.startContinuation(rate_);
    mixer_->start(join_.at, static_cast<int>(rate_), epoch);
    audioActive_ = true;
    join_ = Join{};
    postStatusLocked();
}

void PlaybackController::playingTickLocked() {
    const Sequence *sequence = sequenceLocked();
    if (!sequence || !isPositive(sequence->frameDuration)) {
        pauseLocked();
        return;
    }
    touchIdleLocked();
    const CMTime t = core_->clock.now();
    if (rate_ > 0 && t >= sequence->duration()) {
        pauseLocked(lastFrameStartLocked());
        return;
    }
    if (rate_ < 0 && t <= kCMTimeZero) {
        pauseLocked(kCMTimeZero);
        return;
    }
    const double sinceRetarget = isNumeric(lastRetarget_) ? std::fabs(CMTimeGetSeconds(t - lastRetarget_)) : 1e9;
    if (sinceRetarget >= config_.retargetSeconds) {
        retargetLocked(t, rate_);
    }
    if (audioActive_) {
        const double sincePlan =
            isNumeric(audioPlannedAt_) ? CMTimeGetSeconds(t - audioPlannedAt_) : config_.audioReplanSeconds;
        if (replanAudio_ || sincePlan >= config_.audioReplanSeconds * std::max(1.0, rate_) || sincePlan < 0) {
            planAudioLocked(t);
        }
    } else if (wantsAudio(rate_) && outputStarted_ && !outputFailed_) {
        advanceJoinLocked(t);
    }
    const int64_t frame = frameIndexAt(clampLocked(t), sequence->frameDuration, SnapMode::Floor);
    if (frame != lastPostedFrame_) {
        postStatusLocked();
    }
}

void PlaybackController::pauseLocked(std::optional<CMTime> at) {
    const bool wasPlaying = state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling;
    if (!wasPlaying) {
        if (state_ == PlaybackState::Scrubbing) {
            state_ = PlaybackState::Stopped;
            noteDisplayChangedLocked();
            pendingRetarget_ = std::make_pair(displayTime_, 1.0);
            postStatusLocked();
            tickCv_.notify_all();
        }
        return;
    }
    const CMTime from = state_ == PlaybackState::Playing ? core_->clock.now() : displayTime_;
    const CMTime t = clampLocked(at ? *at : from);
    core_->clock.setTime(t);
    if (mixer_->isRunning()) {
        lastStopSerial_ = mixer_->stop();
        lastStopAt_ = std::chrono::steady_clock::now();
    }
    audioActive_ = false;
    join_ = Join{};
    ++prerollSerial_;
    state_ = PlaybackState::Stopped;
    displayTime_ = t;
    noteDisplayChangedLocked();
    core_->resetFps();
    touchIdleLocked();
    publishDisplayLocked();
    pendingRetarget_ = std::make_pair(t, 1.0);
    requestDisplayFramesLocked(t);
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::handleOutputEventsLocked() {
    std::vector<audio::AudioOutputEvent> events;
    events.swap(outputEvents_);
    for (const audio::AudioOutputEvent &event : events) {
        switch (event.kind) {
        case audio::AudioOutputEvent::Kind::ConfigurationChanged:
            outputStarted_ = event.running;
            if (audioActive_) {
                // New device, new latency: the clock re-reads it now (a small jump at most).
                core_->clock.setOutputLatency(event.latency + mixer_->processingLatency(static_cast<int>(rate_)));
            }
            break;
        case audio::AudioOutputEvent::Kind::RestartFailed:
            outputStarted_ = false;
            outputFailed_ = true;
            lastError_ = PlaybackError{PlaybackErrorCode::AudioDeviceLost, event.message};
            if (state_ == PlaybackState::Playing && audioActive_) {
                dropAudioLocked(); // keep going on the host clock
            }
            postStatusLocked();
            break;
        }
    }
}

bool PlaybackController::manageOutput(std::unique_lock<std::mutex> &lock) {
    const auto now = std::chrono::steady_clock::now();
    const bool transport = state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling;
    const bool wanted = sequenceLocked() != nullptr && (transport || now < idleDeadline_);
    // The output could do better (AutomaticAudioOutput on its fallback with a retry due, or after
    // the device was lost): let it switch when audio is about to start or is missing, never
    // under a running audio clock.
    const bool audioPending = (state_ == PlaybackState::Prerolling && preroll_.wantAudio) ||
                              (state_ == PlaybackState::Playing && wantsAudio(rate_) && outputFailed_);
    const bool retry = audioPending && !audioActive_ && output_->wantsRestart();
    if (wanted && (retry || (!outputStarted_ && !outputFailed_))) {
        lock.unlock();
        const media::Status status = output_->start(); // may take a while: never under mutex_
        lock.lock();
        if (status.ok()) {
            outputStarted_ = true;
            outputFailed_ = false;
        } else {
            outputStarted_ = false;
            outputFailed_ = true;
            lastError_ = PlaybackError{PlaybackErrorCode::AudioOutputUnavailable, status.error().description()};
            postStatusLocked();
        }
        return true;
    }
    if (!wanted && outputStarted_) {
        lock.unlock();
        output_->stop();
        lock.lock();
        outputStarted_ = false;
        return true;
    }
    return false;
}

// MARK: Model

void PlaybackController::setSequence(std::shared_ptr<const Project> project, SequenceId sequenceId) {
    std::lock_guard<std::mutex> lock(mutex_);
    pauseLocked();
    project_ = std::move(project);
    sequenceId_ = sequenceId;
    core_->setSnapshot(project_, sequenceId_, /*newSequence*/ true);
    registerAssetsLocked();
    state_ = PlaybackState::Stopped;
    displayTime_ = kCMTimeZero;
    noteDisplayChangedLocked();
    core_->clock.setTime(kCMTimeZero); // (pauseLocked stopped the mix if it was running)
    publishDisplayLocked();
    mixer_->clearGraph(); // dropped sources go to the reaper via the tick thread
    pendingRetarget_ = std::make_pair(displayTime_, 1.0);
    touchIdleLocked(); // warm the output up for the first play
    requestDisplayFramesLocked(displayTime_);
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::modelChanged(std::shared_ptr<const Project> project) {
    std::lock_guard<std::mutex> lock(mutex_);
    project_ = std::move(project);
    core_->setSnapshot(project_, sequenceId_, /*newSequence*/ false);
    registerAssetsLocked();
    if (!sequenceLocked()) {
        pauseLocked();
        mixer_->clearGraph();
        pendingRetarget_.reset();
        if (pool_) {
            pool_->setTargets({});
        }
        postNeedsDisplay();
        tickCv_.notify_all();
        return;
    }
    switch (state_) {
    case PlaybackState::Playing: {
        const CMTime t = core_->clock.now();
        if (rate_ > 0 && t >= sequenceLocked()->duration()) {
            pauseLocked(lastFrameStartLocked());
            return;
        }
        // The tick thread re-plans within one tick (sources with unchanged mappings play on).
        lastRetarget_ = kCMTimeInvalid;
        replanAudio_ = audioActive_;
        if (join_.active) {
            join_ = Join{}; // re-prime against the new model
        }
        break;
    }
    case PlaybackState::Prerolling:
        preroll_.retargeted = false;
        preroll_.planned = false;
        break;
    case PlaybackState::Stopped:
    case PlaybackState::Scrubbing: {
        const CMTime clamped = clampLocked(displayTime_);
        const bool moved = CMTimeCompare(clamped, displayTime_) != 0;
        displayTime_ = clamped;
        noteDisplayChangedLocked(); // the audio at the paused frame may have changed
        publishDisplayLocked();
        if (state_ != PlaybackState::Scrubbing) {
            pendingRetarget_ = std::make_pair(displayTime_, 1.0);
        }
        requestDisplayFramesLocked(displayTime_);
        if (moved) {
            postStatusLocked(); // the edit moved the playhead (the sequence got shorter)
        }
        break;
    }
    }
    tickCv_.notify_all();
}

void PlaybackController::forgetMedia() {
    std::lock_guard<std::mutex> lock(mutex_);
    registeredPaths_.clear();
    routing_.clear();
}

void PlaybackController::setAssetRouting(AssetId asset, media::RoutedMediaInfo routed) {
    std::lock_guard<std::mutex> lock(mutex_);
    routing_[asset] = std::move(routed);
    registeredPaths_.erase(asset); // re-register with the routing on the next pass
    registerAssetsLocked();
}

// MARK: Transport

void PlaybackController::play() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        return;
    }
    if (rate_ == 0.0) {
        rate_ = 1.0;
    }
    beginPrerollLocked(displayTime_, rate_);
}

void PlaybackController::pause() {
    std::lock_guard<std::mutex> lock(mutex_);
    pauseLocked();
}

void PlaybackController::togglePlay() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        pauseLocked();
    } else {
        if (rate_ == 0.0) {
            rate_ = 1.0;
        }
        beginPrerollLocked(displayTime_, rate_);
    }
}

void PlaybackController::seek(CMTime time, SeekMode mode) {
    std::lock_guard<std::mutex> lock(mutex_);
    const CMTime t = clampLocked(time);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        beginPrerollLocked(t, rate_);
        return;
    }
    if (mode == SeekMode::Exact) {
        state_ = PlaybackState::Stopped;
        pendingRetarget_ = std::make_pair(t, 1.0);
    }
    displayTime_ = t;
    noteDisplayChangedLocked();
    core_->clock.setTime(t);
    publishDisplayLocked();
    requestDisplayFramesLocked(t);
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::setRate(double rate) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (rate == 0.0 || !std::isfinite(rate)) {
        pauseLocked();
        return;
    }
    rate = std::clamp(rate, -8.0, 8.0);
    if (state_ == PlaybackState::Prerolling) {
        beginPrerollLocked(preroll_.at, rate); // still cheap: the tick thread does the work
        return;
    }
    if (state_ != PlaybackState::Playing) {
        if (state_ == PlaybackState::Scrubbing) {
            state_ = PlaybackState::Stopped;
        }
        beginPrerollLocked(displayTime_, rate);
        return;
    }
    if (rate == rate_) {
        return;
    }
    if ((rate > 0) != (rate_ > 0)) {
        // Direction change: decoders run the other way; pre-roll from here.
        beginPrerollLocked(clampLocked(core_->clock.now()), rate);
        return;
    }
    // Same direction: no pre-roll.
    const bool want = wantsAudio(rate);
    if (audioActive_ && want) {
        core_->clock.setOutputLatency(audioLatencyLocked(rate));
        const uint32_t epoch = core_->clock.startContinuation(rate);
        if (!mixer_->changeRate(static_cast<int>(rate), epoch)) {
            beginPrerollLocked(clampLocked(core_->clock.now()), rate);
            return;
        }
    } else if (audioActive_) {
        rate_ = rate;
        dropAudioLocked(); // 2x -> 4x/8x: video on the host clock, audio faded out
    } else {
        const CMTime t = core_->clock.now();
        core_->clock.start(t, rate, ClockMode::HostTime);
        join_ = Join{}; // re-armed by the tick thread for 1x/2x
    }
    rate_ = rate;
    lastRetarget_ = kCMTimeInvalid;
    core_->resetFps();
    publishDisplayLocked();
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::shuttleForward() {
    double next = 1.0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const bool running = state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling;
        if (running && rate_ > 0) {
            next = std::min(8.0, rate_ * 2.0);
        }
    }
    setRate(next);
}

void PlaybackController::shuttleReverse() {
    double next = -1.0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const bool running = state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling;
        if (running && rate_ < 0) {
            next = std::max(-8.0, rate_ * 2.0);
        }
    }
    setRate(next);
}

void PlaybackController::stepFrames(int frames) {
    std::lock_guard<std::mutex> lock(mutex_);
    pauseLocked();
    const Sequence *sequence = sequenceLocked();
    if (!sequence) {
        return;
    }
    state_ = PlaybackState::Stopped;
    const CMTime t = clampLocked(displayTime_ + CMTimeMultiply(sequence->frameDuration, frames));
    displayTime_ = t;
    noteDisplayChangedLocked();
    core_->clock.setTime(t);
    publishDisplayLocked();
    pendingRetarget_ = std::make_pair(t, frames < 0 ? -1.0 : 1.0);
    requestDisplayFramesLocked(t);
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::scrubTo(CMTime time) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        if (mixer_->isRunning()) {
            lastStopSerial_ = mixer_->stop();
            lastStopAt_ = std::chrono::steady_clock::now();
        }
        audioActive_ = false;
        join_ = Join{};
        ++prerollSerial_;
        core_->resetFps();
    }
    state_ = PlaybackState::Scrubbing;
    const CMTime t = clampLocked(time);
    displayTime_ = t;
    noteDisplayChangedLocked();
    core_->clock.setTime(t);
    publishDisplayLocked();
    requestDisplayFramesLocked(t);
    postStatusLocked();
}

void PlaybackController::endScrub() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ != PlaybackState::Scrubbing) {
        return;
    }
    state_ = PlaybackState::Stopped;
    noteDisplayChangedLocked();
    publishDisplayLocked();
    pendingRetarget_ = std::make_pair(displayTime_, 1.0);
    requestDisplayFramesLocked(displayTime_);
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::setMuted(bool muted) {
    std::lock_guard<std::mutex> lock(mutex_);
    muted_ = muted;
    mixer_->setMuted(muted);
}

bool PlaybackController::isMuted() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return muted_;
}

// MARK: State

CMTime PlaybackController::currentTime() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return nowLocked();
}

PlaybackState PlaybackController::state() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return state_;
}

double PlaybackController::rate() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return rate_;
}

PlaybackStatus PlaybackController::status() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return statusLocked();
}

PresentedFrame PlaybackController::lastPresented() const {
    std::lock_guard<std::mutex> lock(core_->presentedMutex);
    return core_->presentedInfo;
}

PlaybackStats PlaybackController::stats() const {
    PlaybackStats s;
    s.presentedFrames = core_->presented.load(std::memory_order_relaxed);
    s.droppedFrames = core_->dropped.load(std::memory_order_relaxed);
    s.lateFrames = core_->late.load(std::memory_order_relaxed);
    s.cacheHits = core_->hits.load(std::memory_order_relaxed);
    s.cacheMisses = core_->misses.load(std::memory_order_relaxed);
    s.mapFailures = core_->mapFailures.load(std::memory_order_relaxed);
    s.monotonicHolds = core_->monotonicHolds.load(std::memory_order_relaxed);
    const uint64_t lookups = s.cacheHits + s.cacheMisses + s.mapFailures;
    s.cacheHitRate = lookups ? static_cast<double>(s.cacheHits) / static_cast<double>(lookups) : 0.0;
    // The HUD rate decays to 0 once presentations stop (paused view, stalled display link).
    const uint64_t lastPresent = core_->lastClockPresentNanos.load(std::memory_order_relaxed);
    const uint64_t hostNow = core_->clock.hostClock()->nowNanos();
    const bool recent = lastPresent > 0 && hostNow - lastPresent < 500'000'000ull;
    s.fps = recent ? core_->fps.load(std::memory_order_relaxed) : 0.0;
    s.clockMode = core_->clock.mode();
    s.clockTime = core_->clock.now();
    s.outputLatency = core_->clock.outputLatency();
    s.cacheBytes = cache_->stats().bytes;

    const audio::AudioMixer::Stats mixerStats = mixer_->stats();
    s.audioUnderruns = mixerStats.underruns;
    s.audioUnderrunFrames = mixerStats.underrunFrames;
    s.audioOutput = output_->kind();
    s.outputRunning = output_->isRunning();

    media::DecodePool::Stats poolStats;
    if (pool_) {
        poolStats = pool_->stats();
        int busy = 0;
        for (const auto &stream : poolStats.streams) {
            busy += stream.idle ? 0 : 1;
        }
        const uint64_t settled = poolStats.scrubServiced + poolStats.scrubCancelled + poolStats.scrubFailed;
        s.decodeQueueDepth = busy + static_cast<int>(poolStats.scrubRequests > settled ? poolStats.scrubRequests - settled : 0);
    }

    std::lock_guard<std::mutex> lock(mutex_);
    s.audioActive = audioActive_;
    s.lastError = lastError_;
    const Sequence *sequence = sequenceLocked();
    if (!sequence) {
        return s;
    }
    const CMTime t = nowLocked();
    const RenderGraph graph = Scheduler::renderGraphAt(*sequence, *project_, t);
    for (const VideoLayer &layer : graph.layers) {
        ActiveClipInfo info;
        info.clip = layer.clipId;
        info.asset = layer.assetId;
        for (const auto &stream : poolStats.streams) {
            if (stream.asset == layer.assetId && stream.lane == layer.clipId.value()) {
                info.backend = stream.backend;
                info.hardware = stream.hardware;
                info.failed = stream.failed;
            }
        }
        s.activeClips.push_back(info);
    }
    for (const Track &track : sequence->audioTracks) {
        const Clip *clip = track.clipAt(t);
        if (!clip || !Scheduler::isTrackActive(*sequence, track)) {
            continue;
        }
        ActiveClipInfo info;
        info.clip = clip->id;
        info.asset = clip->assetId;
        info.isAudio = true;
        for (const auto &source : mixerStats.sources) {
            if (source.asset == clip->assetId && source.track == track.id) {
                info.backend = source.backend;
                info.failed = source.failed;
            }
        }
        s.activeClips.push_back(info);
    }
    return s;
}

void PlaybackController::setObserver(dispatch_queue_t queue, PlaybackObserver observer) {
    std::lock_guard<std::mutex> lock(hub_->mutex);
    hub_->queue = queue;
    hub_->observer = std::move(observer);
}

render::PreviewFrameSource PlaybackController::frameSource() {
    auto core = core_;
    auto state = std::make_shared<Core::RenderState>();
    return [core, state](const render::PreviewFrameRequest &request, render::PreviewFrame &frame) {
        return core->renderFrame(*state, request, frame);
    };
}

// MARK: Tick thread

void PlaybackController::tickMain() {
    std::unique_lock<std::mutex> lock(mutex_);
    while (!stopTick_) {
        // Dropped audio sources are destroyed on the mixer's reaper queue, never here.
        lock.unlock();
        mixer_->collectGarbage();
        lock.lock();
        if (stopTick_) {
            break;
        }
        handleOutputEventsLocked();
        if (manageOutput(lock)) {
            continue; // the lock was released: re-evaluate everything
        }
        if (pendingRetarget_) {
            const auto [at, rate] = *pendingRetarget_;
            pendingRetarget_.reset();
            retargetLocked(at, rate);
        }
        if (state_ == PlaybackState::Prerolling) {
            advancePrerollLocked();
        } else if (state_ == PlaybackState::Playing) {
            playingTickLocked();
        } else {
            warmAudioLocked();
        }
        if (stopTick_ || !outputEvents_.empty() || pendingRetarget_) {
            continue;
        }
        if (state_ == PlaybackState::Prerolling || state_ == PlaybackState::Playing) {
            tickCv_.wait_for(lock, config_.tickInterval);
            continue;
        }
        // Stopped or scrubbing: sleep until the audio should be warmed, the idle output
        // stopped, or something happens.
        const bool warmPending = state_ == PlaybackState::Stopped && !audioWarm_ && sequenceLocked();
        auto wake = std::chrono::steady_clock::time_point::max();
        if (warmPending) {
            const auto warmAt = displayChangedAt_ + config_.audioWarmDelay;
            const auto now = std::chrono::steady_clock::now();
            // Still waiting for the previous run's fade: look again after a tick.
            wake = warmAt > now ? warmAt : now + config_.tickInterval;
        }
        if (outputStarted_) {
            wake = std::min(wake, idleDeadline_);
        }
        if (wake == std::chrono::steady_clock::time_point::max()) {
            tickCv_.wait(lock);
        } else {
            tickCv_.wait_until(lock, wake);
        }
    }
}

} // namespace ve::playback
