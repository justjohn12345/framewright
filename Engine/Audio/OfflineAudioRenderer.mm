#include "OfflineAudioRenderer.h"

#include "../Playback/PlaybackController.h"
#include "../Render/Scheduler.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <thread>

namespace ve::audio {

using media::MediaErrorCode;
using media::makeError;

OfflineAudioRenderer::OfflineAudioRenderer(std::shared_ptr<media::BackendRouter> router,
                                           std::shared_ptr<const Project> project, SequenceId sequenceId,
                                           std::map<AssetId, media::RoutedMediaInfo> routing, Config config)
    : project_(std::move(project)), sequenceId_(sequenceId), config_(config) {
    AudioMixerConfig mixerConfig;
    mixerConfig.sampleRate = config_.sampleRate;
    mixerConfig.channels = config_.channels;
    mixer_ = std::make_unique<AudioMixer>(std::move(router), nullptr, mixerConfig);
    const Sequence *sequence = project_ ? project_->findSequence(sequenceId_) : nullptr;
    if (!sequence) {
        return;
    }
    for (const MediaAsset &asset : project_->assets) {
        if (!asset.hasAudio()) {
            continue;
        }
        std::optional<media::RoutedMediaInfo> routed;
        if (auto it = routing.find(asset.id); it != routing.end()) {
            routed = it->second;
        }
        mixer_->registerAsset(asset.id, playback::mediaPathForURL(asset.url), std::move(routed));
    }
    total_ = std::max<int64_t>(0, mixer_->sampleFor(sequence->duration()));
}

OfflineAudioRenderer::~OfflineAudioRenderer() {
    // Nothing renders any more: the mixer's destructor drops the plans and joins the sources.
    mixer_.reset();
}

void OfflineAudioRenderer::plan(int64_t from) {
    const Sequence *sequence = project_->findSequence(sequenceId_);
    const auto rate = static_cast<int32_t>(config_.sampleRate);
    const int64_t until = std::min(total_, from + static_cast<int64_t>(config_.planSeconds * config_.sampleRate));
    // The same graph the playback controller plans (clips of assets without audio contribute
    // nothing), over [from, until).
    AudioGraph graph = Scheduler::audioGraphFor(*sequence, *project_, TimeRange{CMTimeMake(from, rate),
                                                                                CMTimeMake(until, rate)});
    graph.segments.erase(std::remove_if(graph.segments.begin(), graph.segments.end(),
                                        [&](const AudioSegment &segment) {
                                            const MediaAsset *asset = project_->findAsset(segment.assetId);
                                            return !asset || !asset->hasAudio();
                                        }),
                         graph.segments.end());
    mixer_->setGraph(graph, CMTimeMake(from, rate));
    if (!started_) {
        mixer_->start(CMTimeMake(from, rate), 1, Clock::kAnyEpoch);
        started_ = true;
    }
    mixer_->collectGarbage();
    plannedUntil_ = until;
}

media::Result<int> OfflineAudioRenderer::render(float *dst, int maxFrames, const std::function<bool()> &cancelled) {
    if (!project_ || !project_->findSequence(sequenceId_)) {
        return makeError(MediaErrorCode::InvalidState, "the sequence to mix does not exist");
    }
    if (dst == nullptr || maxFrames <= 0) {
        return makeError(MediaErrorCode::InvalidArgument, "render() needs a buffer");
    }
    const int64_t pos = position_.load(std::memory_order_relaxed);
    if (pos >= total_) {
        return 0;
    }
    const int chunk = std::min<int>(maxFrames, mixer_->config().maxChunkFrames);
    const int n = static_cast<int>(std::min<int64_t>(chunk, total_ - pos));
    const int64_t margin = static_cast<int64_t>(config_.replanMarginSeconds * config_.sampleRate);
    if (plannedUntil_ < 0 || (plannedUntil_ < total_ && pos + n + margin > plannedUntil_)) {
        plan(pos);
    }

    // Wait until every source sounding in [pos, pos + n) has decoded it.
    const auto deadline = std::chrono::steady_clock::now() + config_.stallTimeout;
    while (!mixer_->isRangeReady(pos, n)) {
        if (cancelled && cancelled()) {
            return makeError(MediaErrorCode::Cancelled, "cancelled");
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            return makeError(MediaErrorCode::Timeout,
                             "audio decoding stalled at " + std::to_string(pos / config_.sampleRate) + " s");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (auto failed = mixer_->failedSourceIn(pos, n)) {
        const MediaAsset *asset = project_->findAsset(failed->asset);
        const std::string name = asset ? asset->name : "asset " + std::to_string(failed->asset.value());
        return makeError(MediaErrorCode::DecodeFailed,
                         "the audio of “" + name + "” could not be decoded" +
                             (failed->error.empty() ? std::string() : ": " + failed->error));
    }

    const uint64_t underrunsBefore = mixer_->underrunFrames();
    mixer_->render(dst, n, config_.channels, 0);
    if (mixer_->underrunFrames() != underrunsBefore) {
        return makeError(MediaErrorCode::Internal, "the audio mix underran at " +
                                                       std::to_string(pos / config_.sampleRate) + " s");
    }
    if (mixer_->position() != pos + n) {
        return makeError(MediaErrorCode::Internal, "the audio mix lost its position");
    }
    position_.store(pos + n, std::memory_order_release);
    return n;
}

} // namespace ve::audio
