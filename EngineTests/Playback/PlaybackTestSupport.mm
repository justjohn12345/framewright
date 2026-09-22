#include "PlaybackTestSupport.h"

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Model/Validation.h"
#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"

#import <Metal/Metal.h>

#include <cmath>
#include <thread>

namespace ve::test {

using namespace ve::playback;

PlaybackHarness::PlaybackHarness(Mode mode, double captureSeconds) {
    router = media::BackendRouter::makeDefault();
    cache = std::make_shared<media::FrameCache>();
    pool = std::make_shared<media::DecodePool>(router, cache);
    host = mode == Mode::Manual ? audio::HostClock::makeVirtual() : audio::HostClock::system();

    PlaybackConfig config;
    config.hostClock = host;
    config.makeOutput = [this, mode, captureSeconds](audio::AudioMixer &mixer, audio::Clock &) {
        audio::NullAudioOutputConfig c;
        c.mode = mode == Mode::Manual ? audio::NullAudioOutputConfig::Mode::Manual
                                      : audio::NullAudioOutputConfig::Mode::Realtime;
        c.virtualClock = mode == Mode::Manual ? host : nullptr;
        c.blockFrames = 512;
        c.captureFrames = static_cast<size_t>(captureSeconds * mixer.sampleRate());
        auto out = std::make_unique<audio::NullAudioOutput>(mixer, c);
        output = out.get();
        return std::unique_ptr<audio::IAudioOutput>(std::move(out));
    };
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
    clip.sourceOut = sourceIn + frames30(durationFrames);
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
    Sample s;
    render::PreviewFrameRequest request;
    request.textureCache = &textures_;
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
    // Exact rational arithmetic (speed 1): source = sourceIn + (t - start), nearest source frame.
    const CMTime source = clip->sourceIn + (frames30(sequenceFrame) - clip->timelineStart);
    const int64_t lastFrame = frameIndexAt(asset->duration, asset->frameDuration, SnapMode::Ceil) - 1;
    return std::clamp<int64_t>(frameIndexAt(source, asset->frameDuration, SnapMode::Round), 0, lastFrame);
}

} // namespace ve::test
