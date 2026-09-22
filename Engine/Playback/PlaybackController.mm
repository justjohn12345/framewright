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

namespace {

/// Media paths are absolute POSIX paths; the model may hold file URLs.
std::string mediaPath(const std::string &url) {
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

CMTime lastFrameStartOf(const Sequence &sequence) {
    const CMTime duration = sequence.duration();
    if (!(duration > kCMTimeZero) || !isPositive(sequence.frameDuration)) {
        return kCMTimeZero;
    }
    const int64_t frames = frameIndexAt(duration, sequence.frameDuration, SnapMode::Ceil);
    return timeForFrame(std::max<int64_t>(0, frames - 1), sequence.frameDuration);
}

int64_t slotFor(const VideoLayer &layer, const MediaAsset &asset) {
    return asset.isStill() ? 0 : FrameCache::frameIndex(layer.sourceTime, asset.frameDuration);
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

        bool hasFrame = false;
        int64_t lastFrame = -1;
        uint64_t lastSnapshotVersion = 0;
        uint64_t lastFrameVersion = 0;
        bool lastComplete = false;
        bool lastClockDriven = false;
        uint32_t lastEpoch = 0; // clock epoch of the last presentation (a seek starts a new one)
        uint64_t lastPresentNanos = 0;
        std::vector<ClipId> lastClips;
        std::vector<render::TextureSet> lastTextures;
        std::vector<int64_t> lastShown;
        std::vector<FrameCache::PinnedFrame> pins; // index-aligned with lastClips

        std::vector<ClipId> nextClips;
        std::vector<int64_t> nextShown;
        std::vector<FrameCache::PinnedFrame> nextPins;
        PresentedFrame info;
    };

    audio::Clock clock;
    const std::shared_ptr<FrameCache> cache;

    std::mutex snapshotMutex; // held only to copy/replace the pointer
    std::shared_ptr<const Project> project;
    SequenceId sequenceId;
    std::atomic<uint64_t> snapshotVersion{1};

    audio::SeqLock<Display> display;
    std::atomic<uint64_t> frameVersion{0};

    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<uint64_t> late{0};
    std::atomic<uint64_t> hits{0};
    std::atomic<uint64_t> misses{0};
    std::atomic<double> fps{0.0};

    mutable std::mutex presentedMutex;
    PresentedFrame presentedInfo;

    void setSnapshot(std::shared_ptr<const Project> p, SequenceId id) {
        {
            std::lock_guard<std::mutex> lock(snapshotMutex);
            project = std::move(p);
            sequenceId = id;
        }
        snapshotVersion.fetch_add(1, std::memory_order_acq_rel);
    }

    bool renderFrame(RenderState &rs, const render::PreviewFrameRequest &request, render::PreviewFrame &frame);
};

bool PlaybackController::Core::renderFrame(RenderState &rs, const render::PreviewFrameRequest &request,
                                           render::PreviewFrame &frame) {
    const uint64_t version = snapshotVersion.load(std::memory_order_acquire);
    if (version != rs.snapshotVersion) {
        std::shared_ptr<const Project> previous;
        {
            std::lock_guard<std::mutex> lock(snapshotMutex);
            previous = std::move(rs.project);
            rs.project = project;
            rs.sequenceId = sequenceId;
        }
        rs.snapshotVersion = version;
    }
    const Sequence *sequence = rs.project ? rs.project->findSequence(rs.sequenceId) : nullptr;
    if (!sequence || !isPositive(sequence->frameDuration)) {
        if (!rs.hasFrame) {
            return false;
        }
        frame.graph = RenderGraph{};
        frame.textures.clear();
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
        const bool useTarget = request.targetTimestamp > 0 && !clock.hostClock()->isVirtual();
        t = useTarget ? clock.timeAt(audio::HostClock::secondsToNanos(request.targetTimestamp)) : clock.now();
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
    frame.textures.resize(n);
    rs.nextClips.clear();
    rs.nextShown.clear();
    rs.nextPins.clear();
    rs.info.layers.clear();
    bool complete = true;
    for (size_t i = 0; i < n; ++i) {
        const VideoLayer &layer = graph.layers[i];
        PresentedLayer shown;
        shown.clip = layer.clipId;
        shown.asset = layer.assetId;
        render::TextureSet textures;
        FrameCache::PinnedFrame pin;
        int64_t shownIndex = -1;
        if (const MediaAsset *asset = rs.project->findAsset(layer.assetId)) {
            const int64_t slot = slotFor(layer, *asset);
            shown.wantedIndex = slot;
            pin = cache->acquire(layer.assetId, slot);
            if (pin) {
                hits.fetch_add(1, std::memory_order_relaxed);
                if (request.textureCache) {
                    auto mapped = request.textureCache->textures(pin.image());
                    if (mapped.ok()) {
                        textures = std::move(mapped).value();
                    }
                }
                shownIndex = pin.frame().index;
                shown.exact = true;
            } else {
                misses.fetch_add(1, std::memory_order_relaxed);
                complete = false;
                // Keep the clip's previous picture up until its frame lands.
                for (size_t j = 0; j < rs.lastClips.size(); ++j) {
                    if (rs.lastClips[j] == layer.clipId) {
                        textures = rs.lastTextures[j];
                        pin = std::move(rs.pins[j]);
                        shownIndex = rs.lastShown[j];
                        rs.lastClips[j] = ClipId{};
                        break;
                    }
                }
            }
        }
        shown.shownIndex = shownIndex;
        frame.textures[i] = std::move(textures);
        rs.nextClips.push_back(layer.clipId);
        rs.nextShown.push_back(shownIndex);
        rs.nextPins.push_back(std::move(pin));
        rs.info.layers.push_back(shown);
    }

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
    }

    frame.graph = std::move(graph);
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
        output_ = config_.makeOutput(*mixer_, core_->clock);
    }
    if (!output_) {
        output_ = std::make_unique<audio::AutomaticAudioOutput>(*mixer_, &core_->clock);
    }
    publishDisplayLocked();
    tickThread_ = std::thread([this] { tickMain(); });
}

PlaybackController::~PlaybackController() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopTick_ = true;
        stopPipelineLocked();
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

void PlaybackController::publishDisplayLocked() {
    Core::Display d;
    d.value = displayTime_.value;
    d.timescale = displayTime_.timescale > 0 ? displayTime_.timescale : 1;
    d.clockDriven = state_ == PlaybackState::Playing;
    d.rate = rate_;
    core_->display.store(d);
}

void PlaybackController::postStatusLocked() {
    const CMTime t = nowLocked();
    if (const Sequence *sequence = sequenceLocked(); sequence && isPositive(sequence->frameDuration)) {
        lastPostedFrame_ = frameIndexAt(t, sequence->frameDuration, SnapMode::Floor);
    }
    hub_->postStatus(PlaybackStatus{t, state_, rate_});
}

void PlaybackController::postNeedsDisplay() {
    hub_->postNeedsDisplay();
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
    const Sequence *sequence = sequenceLocked();
    if (!sequence) {
        mixer_->clearGraph();
        return;
    }
    const CMTime from = maxTime(kCMTimeZero, at - CMTimeMake(1, 10));
    const CMTime to = at + CMTimeMakeWithSeconds(config_.audioHorizonSeconds, kPreciseTimescale);
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
    for (const VideoLayer &layer : graph.layers) {
        const MediaAsset *asset = project_->findAsset(layer.assetId);
        if (!asset || cache_->contains(layer.assetId, slotFor(layer, *asset))) {
            continue;
        }
        pool_->requestFrame(layer.assetId, layer.sourceTime, [weakCore, weakHub](media::Result<media::ScrubFrame> r) {
            if (!r.ok()) {
                return;
            }
            if (auto core = weakCore.lock()) {
                core->frameVersion.fetch_add(1, std::memory_order_acq_rel);
            }
            if (auto hub = weakHub.lock()) {
                hub->postNeedsDisplay();
            }
        });
    }
    postNeedsDisplay();
}

void PlaybackController::stopPipelineLocked() {
    mixer_->stop();
    output_->stop();
    audioActive_ = false;
}

void PlaybackController::startPlaybackLocked(CMTime at, double rate) {
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
    rate_ = rate;
    displayTime_ = at;
    state_ = PlaybackState::Prerolling;
    publishDisplayLocked();
    postStatusLocked();

    const auto deadline = std::chrono::steady_clock::now() + config_.prerollTimeout;
    const bool wantAudio = !muted_ && (rate == 1.0 || rate == 2.0);
    retargetLocked(at, rate);
    if (wantAudio) {
        planAudioLocked(at);
        mixer_->prime(at, config_.prerollTimeout);
    }
    // Wait (bounded) for the first frames.
    const RenderGraph graph = Scheduler::renderGraphAt(*sequence, *project_, at);
    for (;;) {
        bool ready = true;
        for (const VideoLayer &layer : graph.layers) {
            const MediaAsset *asset = project_->findAsset(layer.assetId);
            if (asset && !cache_->contains(layer.assetId, slotFor(layer, *asset))) {
                ready = false;
                break;
            }
        }
        if (ready || std::chrono::steady_clock::now() >= deadline) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }

    audioActive_ = false;
    if (wantAudio) {
        const uint32_t epoch = core_->clock.start(at, rate, ClockMode::AudioSamples);
        mixer_->start(at, static_cast<int>(rate), epoch);
        if (output_->start().ok()) {
            audioActive_ = true;
        } else {
            mixer_->stop();
        }
    }
    if (!audioActive_) {
        core_->clock.start(at, rate, ClockMode::HostTime);
    }
    state_ = PlaybackState::Playing;
    lastRetarget_ = at;
    publishDisplayLocked();
    postStatusLocked();
    tickCv_.notify_all();
}

void PlaybackController::pauseLocked(std::optional<CMTime> at) {
    const bool wasPlaying = state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling;
    if (!wasPlaying) {
        if (state_ == PlaybackState::Scrubbing) {
            state_ = PlaybackState::Stopped;
            retargetLocked(displayTime_, 1.0);
            postStatusLocked();
        }
        return;
    }
    const CMTime t = clampLocked(at ? *at : core_->clock.now());
    core_->clock.setTime(t);
    stopPipelineLocked();
    state_ = PlaybackState::Stopped;
    displayTime_ = t;
    publishDisplayLocked();
    retargetLocked(t, 1.0);
    requestDisplayFramesLocked(t);
    postStatusLocked();
}

// MARK: Model

void PlaybackController::setSequence(std::shared_ptr<const Project> project, SequenceId sequenceId) {
    std::lock_guard<std::mutex> lock(mutex_);
    pauseLocked();
    project_ = std::move(project);
    sequenceId_ = sequenceId;
    core_->setSnapshot(project_, sequenceId_);
    registerAssetsLocked();
    state_ = PlaybackState::Stopped;
    displayTime_ = kCMTimeZero;
    core_->clock.setTime(kCMTimeZero);
    publishDisplayLocked();
    mixer_->clearGraph();
    retargetLocked(displayTime_, 1.0);
    requestDisplayFramesLocked(displayTime_);
    postStatusLocked();
}

void PlaybackController::modelChanged(std::shared_ptr<const Project> project) {
    std::lock_guard<std::mutex> lock(mutex_);
    project_ = std::move(project);
    core_->setSnapshot(project_, sequenceId_);
    registerAssetsLocked();
    if (!sequenceLocked()) {
        pauseLocked();
        mixer_->clearGraph();
        if (pool_) {
            pool_->setTargets({});
        }
        postNeedsDisplay();
        return;
    }
    if (state_ == PlaybackState::Playing) {
        const CMTime t = core_->clock.now();
        if (t >= sequenceLocked()->duration()) {
            pauseLocked(lastFrameStartLocked());
            return;
        }
        retargetLocked(t, rate_);
        if (audioActive_) {
            planAudioLocked(t);
        }
        return;
    }
    displayTime_ = clampLocked(displayTime_);
    publishDisplayLocked();
    if (state_ != PlaybackState::Scrubbing) {
        retargetLocked(displayTime_, 1.0);
    }
    requestDisplayFramesLocked(displayTime_);
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
    startPlaybackLocked(displayTime_, rate_);
}

void PlaybackController::pause() {
    std::lock_guard<std::mutex> lock(mutex_);
    pauseLocked();
}

void PlaybackController::togglePlay() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        pauseLocked();
    } else {
        if (rate_ == 0.0) {
            rate_ = 1.0;
        }
        startPlaybackLocked(displayTime_, rate_);
    }
}

void PlaybackController::seek(CMTime time, SeekMode mode) {
    std::lock_guard<std::mutex> lock(mutex_);
    const CMTime t = clampLocked(time);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        stopPipelineLocked();
        startPlaybackLocked(t, rate_);
        return;
    }
    if (mode == SeekMode::Exact) {
        state_ = PlaybackState::Stopped;
        retargetLocked(t, 1.0);
    }
    displayTime_ = t;
    core_->clock.setTime(t);
    publishDisplayLocked();
    requestDisplayFramesLocked(t);
    postStatusLocked();
}

void PlaybackController::setRate(double rate) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (rate == 0.0 || !std::isfinite(rate)) {
        pauseLocked();
        return;
    }
    rate = std::clamp(rate, -8.0, 8.0);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        const CMTime t = clampLocked(core_->clock.now());
        core_->clock.setTime(t);
        stopPipelineLocked();
        startPlaybackLocked(t, rate);
        return;
    }
    if (state_ == PlaybackState::Scrubbing) {
        state_ = PlaybackState::Stopped;
    }
    startPlaybackLocked(displayTime_, rate);
}

void PlaybackController::shuttleForward() {
    double next = 1.0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == PlaybackState::Playing && rate_ > 0) {
            next = std::min(8.0, rate_ * 2.0);
        }
    }
    setRate(next);
}

void PlaybackController::shuttleReverse() {
    double next = -1.0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == PlaybackState::Playing && rate_ < 0) {
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
    core_->clock.setTime(t);
    publishDisplayLocked();
    retargetLocked(t, frames < 0 ? -1.0 : 1.0);
    requestDisplayFramesLocked(t);
    postStatusLocked();
}

void PlaybackController::scrubTo(CMTime time) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == PlaybackState::Playing || state_ == PlaybackState::Prerolling) {
        core_->clock.stop();
        stopPipelineLocked();
    }
    state_ = PlaybackState::Scrubbing;
    const CMTime t = clampLocked(time);
    displayTime_ = t;
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
    publishDisplayLocked();
    retargetLocked(displayTime_, 1.0);
    requestDisplayFramesLocked(displayTime_);
    postStatusLocked();
}

void PlaybackController::setMuted(bool muted) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (muted_ == muted) {
        return;
    }
    muted_ = muted;
    if (state_ == PlaybackState::Playing) {
        const CMTime t = clampLocked(core_->clock.now());
        core_->clock.setTime(t);
        stopPipelineLocked();
        startPlaybackLocked(t, rate_);
    }
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
    const uint64_t lookups = s.cacheHits + s.cacheMisses;
    s.cacheHitRate = lookups ? static_cast<double>(s.cacheHits) / static_cast<double>(lookups) : 0.0;
    s.fps = core_->fps.load(std::memory_order_relaxed);
    s.clockMode = core_->clock.mode();
    s.clockTime = core_->clock.now();
    s.cacheBytes = cache_->stats().bytes;

    const audio::AudioMixer::Stats mixerStats = mixer_->stats();
    s.audioUnderruns = mixerStats.underruns;
    s.audioUnderrunFrames = mixerStats.underrunFrames;
    s.audioOutput = output_->kind();

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
        if (state_ != PlaybackState::Playing) {
            tickCv_.wait(lock, [&] { return stopTick_ || state_ == PlaybackState::Playing; });
            continue;
        }
        tickCv_.wait_for(lock, config_.tickInterval);
        if (stopTick_ || state_ != PlaybackState::Playing) {
            continue;
        }
        const Sequence *sequence = sequenceLocked();
        if (!sequence || !isPositive(sequence->frameDuration)) {
            pauseLocked();
            continue;
        }
        const CMTime t = core_->clock.now();
        if (rate_ > 0 && t >= sequence->duration()) {
            pauseLocked(lastFrameStartLocked());
            continue;
        }
        if (rate_ < 0 && t <= kCMTimeZero) {
            pauseLocked(kCMTimeZero);
            continue;
        }
        const double sinceRetarget = isNumeric(lastRetarget_) ? std::fabs(CMTimeGetSeconds(t - lastRetarget_)) : 1e9;
        if (sinceRetarget >= config_.retargetSeconds) {
            retargetLocked(t, rate_);
        }
        if (audioActive_) {
            const double sincePlan =
                isNumeric(audioPlannedAt_) ? CMTimeGetSeconds(t - audioPlannedAt_) : config_.audioReplanSeconds;
            if (sincePlan >= config_.audioReplanSeconds || sincePlan < 0) {
                planAudioLocked(t);
            }
        }
        const int64_t frame = frameIndexAt(clampLocked(t), sequence->frameDuration, SnapMode::Floor);
        if (frame != lastPostedFrame_) {
            postStatusLocked();
        }
    }
}

} // namespace ve::playback
