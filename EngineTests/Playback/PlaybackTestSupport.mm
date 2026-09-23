#include "PlaybackTestSupport.h"

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Model/Validation.h"
#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <cmath>
#include <thread>

namespace ve::test {

using namespace ve::playback;

// MARK: - ScriptedAudioOutput

ScriptedAudioOutput::ScriptedAudioOutput(audio::AudioMixer &mixer, int blockFrames, size_t captureFrames)
    : mixer_(mixer), blockFrames_(blockFrames), captureFrames_(captureFrames) {
    buffer_.assign(static_cast<size_t>(blockFrames_ * mixer_.channels()), 0.0f);
    resetCapture();
}

media::Status ScriptedAudioOutput::start() {
    startAttempts.fetch_add(1);
    {
        std::unique_lock<std::mutex> lock(gateMutex_);
        gateCv_.wait(lock, [&] { return !gateClosed_; });
    }
    starts.fetch_add(1);
    if (failStart.load()) {
        running_.store(false, std::memory_order_release);
        return media::makeError(media::MediaErrorCode::InvalidState, "scripted output: start refused");
    }
    running_.store(true, std::memory_order_release);
    return media::okStatus();
}

void ScriptedAudioOutput::stop() {
    stops.fetch_add(1);
    running_.store(false, std::memory_order_release);
}

void ScriptedAudioOutput::setEventHandler(audio::AudioOutputEventHandler handler) {
    std::lock_guard<std::mutex> lock(handlerMutex_);
    handler_ = std::move(handler);
}

void ScriptedAudioOutput::emit(const audio::AudioOutputEvent &event) {
    if (event.kind == audio::AudioOutputEvent::Kind::RestartFailed) {
        running_.store(false, std::memory_order_release);
    }
    std::lock_guard<std::mutex> lock(handlerMutex_);
    if (handler_) {
        handler_(event);
    }
}

void ScriptedAudioOutput::setStartGate(bool closed) {
    {
        std::lock_guard<std::mutex> lock(gateMutex_);
        gateClosed_ = closed;
    }
    gateCv_.notify_all();
}

int ScriptedAudioOutput::renderAt(uint64_t ioHostNanos) {
    if (!running_.load(std::memory_order_acquire)) {
        return 0;
    }
    const int ch = mixer_.channels();
    mixer_.render(buffer_.data(), blockFrames_, ch, ioHostNanos);
    if (muted_.load(std::memory_order_relaxed)) {
        std::fill(buffer_.begin(), buffer_.end(), 0.0f);
    }
    if (captureFrames_ > 0 && mixer_.lastRenderWasRunning()) {
        std::lock_guard<std::mutex> lock(captureMutex_);
        const size_t capacity = captureFrames_ * static_cast<size_t>(ch);
        if (capture_.samples.size() < capacity) {
            if (capture_.firstSequenceSample < 0) {
                capture_.firstSequenceSample = mixer_.lastRenderStartSample();
            }
            const size_t take = std::min(buffer_.size(), capacity - capture_.samples.size());
            capture_.samples.insert(capture_.samples.end(), buffer_.begin(), buffer_.begin() + static_cast<long>(take));
        }
    }
    return blockFrames_;
}

audio::NullAudioOutput::Capture ScriptedAudioOutput::capture() const {
    std::lock_guard<std::mutex> lock(captureMutex_);
    return capture_;
}

void ScriptedAudioOutput::resetCapture() {
    std::lock_guard<std::mutex> lock(captureMutex_);
    capture_ = audio::NullAudioOutput::Capture{};
    capture_.channels = mixer_.channels();
    capture_.samples.reserve(captureFrames_ * static_cast<size_t>(mixer_.channels()));
}

// MARK: - ToneRig

ToneRig::ToneRig(int clipCount, const std::function<void(PlaybackConfig &)> &adjust)
    : tones(std::make_shared<ToneBehavior>()), router(makeToneRouter(tones)),
      cache(std::make_shared<media::FrameCache>()), pool(std::make_shared<media::DecodePool>(router, cache)),
      host(audio::HostClock::makeVirtual()) {
    const double sr = 48000.0;
    tones->lengthFrames = static_cast<int64_t>(20 * sr);
    PlaybackConfig config;
    config.hostClock = host;
    config.makeOutput = [this, sr](audio::AudioMixer &mixer) {
        auto o = std::make_unique<ScriptedAudioOutput>(mixer, 512, static_cast<size_t>(10 * sr));
        out = o.get();
        return std::unique_ptr<audio::IAudioOutput>(std::move(o));
    };
    if (adjust) {
        adjust(config);
    }
    controller = std::make_unique<PlaybackController>(router, cache, pool, config);
    sequenceId = project.addSequence("Tones", CMTimeMake(1, 30), 1920, 1080, 1, 1);
    Sequence &seq = *project.findSequence(sequenceId);
    for (int k = 0; k < clipCount; ++k) {
        const std::string path = "tone://" + std::to_string(k);
        tones->setSignal(path, sineSignal(300.0 + 100.0 * k, 0.5));
        MediaAsset asset;
        asset.name = path;
        asset.url = path;
        asset.kind = AssetKind::Audio;
        asset.duration = CMTimeMake(20 * 48000, 48000);
        asset.audioSampleRate = 48000;
        asset.audioChannels = 2;
        assets.push_back(project.addAsset(asset));
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = assets.back();
        clip.trackId = seq.audioTracks[0].id;
        clip.timelineStart = CMTimeMake(10 * k, 1);
        clip.sourceIn = kCMTimeZero;
        clip.timelineDuration = CMTimeMake(10, 1);
        seq.audioTracks[0].clips.push_back(clip);
        clips.push_back(clip.id);
    }
    seq.audioTracks[0].sortClips();
}

ToneRig::~ToneRig() {
    stopPump();
    tones->setReadsBlocked(false);
    if (out) {
        out->setStartGate(false);
    }
    controller.reset();
}

void ToneRig::load() {
    controller->setSequence(std::make_shared<const Project>(project), sequenceId);
}

void ToneRig::publish() {
    controller->modelChanged(std::make_shared<const Project>(project));
}

void ToneRig::renderBlock() {
    const uint64_t blockNanos = static_cast<uint64_t>(512.0 * 1e9 / 48000.0);
    out->renderAt(host->nowNanos() + blockNanos);
    host->advance(blockNanos);
}

void ToneRig::startPump(std::chrono::microseconds period) {
    pumping_ = true;
    pump_ = std::thread([this, period] {
        while (pumping_.load()) {
            renderBlock();
            std::this_thread::sleep_for(period);
        }
    });
}

void ToneRig::stopPump() {
    pumping_ = false;
    if (pump_.joinable()) {
        pump_.join();
    }
}

bool ToneRig::waitForState(PlaybackState state, std::chrono::milliseconds timeout) {
    return PlaybackHarness::waitUntil([&] { return controller->state() == state; }, timeout);
}

uint64_t ToneRig::producerWakeups() const {
    uint64_t sum = 0;
    for (const auto &source : controller->mixer().stats().sources) {
        sum += source.wakeups;
    }
    return sum;
}

// MARK: - PlaybackHarness

PlaybackHarness::PlaybackHarness(Mode mode, double captureSeconds,
                                 const std::function<void(PlaybackConfig &)> &adjust) {
    router = media::BackendRouter::makeDefault();
    // Both backends, as in the app: Apple for what AVFoundation plays, FFmpeg for the rest
    // (MKV). A default router that already has FFmpeg refuses the duplicate, which is fine.
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    cache = std::make_shared<media::FrameCache>();
    pool = std::make_shared<media::DecodePool>(router, cache);
    host = mode == Mode::Realtime ? audio::HostClock::system() : audio::HostClock::makeVirtual();

    PlaybackConfig config;
    config.hostClock = host;
    config.makeOutput = [this, mode, captureSeconds](audio::AudioMixer &mixer) -> std::unique_ptr<audio::IAudioOutput> {
        const size_t captureFrames = static_cast<size_t>(captureSeconds * mixer.sampleRate());
        if (mode == Mode::Scripted) {
            auto out = std::make_unique<ScriptedAudioOutput>(mixer, 512, captureFrames);
            scripted = out.get();
            return out;
        }
        audio::NullAudioOutputConfig c;
        c.mode = mode == Mode::Manual ? audio::NullAudioOutputConfig::Mode::Manual
                                      : audio::NullAudioOutputConfig::Mode::Realtime;
        c.virtualClock = mode == Mode::Manual ? host : nullptr;
        c.blockFrames = 512;
        c.captureFrames = captureFrames;
        auto out = std::make_unique<audio::NullAudioOutput>(mixer, c);
        output = out.get();
        return out;
    };
    if (adjust) {
        adjust(config);
    }
    controller = std::make_unique<PlaybackController>(router, cache, pool, config);
    source_ = controller->frameSource();

    auto tc = render::TextureCache::create(MTLCreateSystemDefaultDevice());
    if (tc.ok()) {
        textures_ = std::move(tc).value();
    } else {
        error_ = tc.error().description();
    }

    project.name = "Playback";
    sequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 2, 1);
    v1 = sequence().videoTracks[0].id;
    v2 = sequence().videoTracks[1].id;
    a1 = sequence().audioTracks[0].id;
}

PlaybackHarness::~PlaybackHarness() {
    source_ = nullptr;
    controller.reset();
}

AssetId PlaybackHarness::importAsset(const std::string &file) {
    std::string mediaError;
    const std::string path = testMediaPath(file, mediaError);
    if (path.empty()) {
        error_ = mediaError;
        return AssetId{};
    }
    return importAssetAtPath(path);
}

AssetId PlaybackHarness::importAssetAtPath(const std::string &path) {
    auto routed = router->probe(path);
    if (!routed.ok()) {
        error_ = routed.error().description();
        return AssetId{};
    }
    const AssetId id = project.ids.make<AssetId>();
    auto asset = media::makeMediaAsset(*routed, id);
    if (!asset.ok()) {
        error_ = asset.error().description();
        return AssetId{};
    }
    project.assets.push_back(*asset);
    controller->setAssetRouting(id, *routed);
    return id;
}

ClipId PlaybackHarness::addClip(TrackId track, AssetId asset, int64_t startFrame, int64_t durationFrames,
                                CMTime sourceIn) {
    Clip clip;
    clip.id = project.ids.make<ClipId>();
    clip.assetId = asset;
    clip.trackId = track;
    clip.timelineStart = frames30(startFrame);
    clip.sourceIn = sourceIn;
    clip.timelineDuration = frames30(durationFrames);
    Track &t = *sequence().findTrack(track);
    t.clips.push_back(clip);
    t.sortClips();
    return clip.id;
}

void PlaybackHarness::link(ClipId a, ClipId b) {
    sequence().findClip(a)->linkedClipId = b;
    sequence().findClip(b)->linkedClipId = a;
}

void PlaybackHarness::addTransition(TrackId track, ClipId from, ClipId to, int64_t frames) {
    Transition t;
    t.id = project.ids.make<TransitionId>();
    t.trackId = track;
    t.fromClipId = from;
    t.toClipId = to;
    t.duration = frames30(frames);
    sequence().transitions.push_back(t);
}

void PlaybackHarness::setClipGain(ClipId clip, double gainDb) {
    sequence().findClip(clip)->audio.gainDb = gainDb;
}

void PlaybackHarness::moveClipToTrack(ClipId clipId, TrackId trackId) {
    Clip moved = *sequence().findClip(clipId);
    Track &from = *sequence().findTrack(moved.trackId);
    from.clips.erase(
        std::remove_if(from.clips.begin(), from.clips.end(), [&](const Clip &c) { return c.id == clipId; }),
        from.clips.end());
    moved.trackId = trackId;
    Track &to = *sequence().findTrack(trackId);
    to.clips.push_back(moved);
    to.sortClips();
}

void PlaybackHarness::slipClip(ClipId clipId, CMTime sourceIn) {
    sequence().findClip(clipId)->sourceIn = sourceIn; // the timeline length stays
}

std::optional<std::string> PlaybackHarness::problem() const {
    return validateProject(project);
}

void PlaybackHarness::load() {
    controller->setSequence(std::make_shared<const Project>(project), sequenceId);
}

void PlaybackHarness::publishEdit() {
    controller->modelChanged(std::make_shared<const Project>(project));
}

PlaybackHarness::Sample PlaybackHarness::present() {
    render::PreviewFrameRequest request;
    request.textureCache = &textures_;
    return presentWith(request);
}

PlaybackHarness::Sample PlaybackHarness::presentAt(double targetSeconds) {
    render::PreviewFrameRequest request;
    request.textureCache = &textures_;
    request.targetTimestamp = targetSeconds;
    return presentWith(request);
}

PlaybackHarness::Sample PlaybackHarness::presentWith(const render::PreviewFrameRequest &request) {
    Sample s;
    s.clockBefore = controller->clock().now();
    s.changed = source_(request, frame_);
    s.clockAfter = controller->clock().now();
    s.presented = controller->lastPresented();
    for (size_t i = 0; i < frame_.graph.layers.size(); ++i) {
        s.clips.push_back(frame_.graph.layers[i].clipId);
        const render::TextureSet &t = i < frame_.textures.size() ? frame_.textures[i] : render::TextureSet();
        s.burnIns.push_back(t ? readBurnIn(t.pixelBuffer().get()) : std::nullopt);
    }
    return s;
}

PlaybackHarness::Sample PlaybackHarness::presentExact(std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    Sample s = present();
    for (;;) {
        const bool exact = std::all_of(s.presented.layers.begin(), s.presented.layers.end(),
                                       [](const PresentedLayer &l) { return l.exact; });
        if (exact || std::chrono::steady_clock::now() >= deadline) {
            return s;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        s = present();
    }
}

int64_t PlaybackHarness::expectedSlot(ClipId clipId, int64_t sequenceFrame) const {
    const Sequence &seq = *project.findSequence(sequenceId);
    const Clip *clip = seq.findClip(clipId);
    const MediaAsset *asset = clip ? project.findAsset(clip->assetId) : nullptr;
    if (!clip || !asset) {
        return -1;
    }
    // Exact rational arithmetic (speed 1): source = sourceIn + (t - start); the source frame on
    // screen is the one that starts at or before it (Scheduler::sourceFrameTime).
    const CMTime source = clip->sourceIn + (frames30(sequenceFrame) - clip->timelineStart);
    const int64_t lastFrame = frameIndexAt(asset->duration, asset->frameDuration, SnapMode::Ceil) - 1;
    return std::clamp<int64_t>(frameIndexAt(source, asset->frameDuration, SnapMode::Floor), 0, lastFrame);
}

bool PlaybackHarness::waitUntil(const std::function<bool()> &condition, std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!condition()) {
        if (std::chrono::steady_clock::now() >= deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

bool PlaybackHarness::waitForState(PlaybackState state, std::chrono::milliseconds timeout) {
    return waitUntil([&] { return controller->state() == state; }, timeout);
}

double PlaybackHarness::playAndWait(std::chrono::milliseconds timeout) {
    const auto t0 = std::chrono::steady_clock::now();
    controller->play();
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    return waitForState(PlaybackState::Playing, timeout) ? ms : -1.0;
}

} // namespace ve::test
