#include "PausedSeekRig.h"

#include "../../Engine/Audio/AudioOutput.h"
#include "../../Engine/Audio/PowerSource.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Render/Scheduler.h"

#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cmath>
#include <sstream>
#include <thread>

namespace ve::test {

using playback::PlaybackController;
using playback::PresentedFrame;
using playback::PresentedLayer;

namespace {

bool less(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) < 0;
}

std::string secondsText(CMTime t) {
    if (!CMTIME_IS_NUMERIC(t)) {
        return "none";
    }
    std::ostringstream s;
    s.precision(4);
    s << std::fixed << CMTimeGetSeconds(t);
    return s.str();
}

} // namespace

// MARK: - SampleTable

CMTime SampleTable::frameAt(CMTime t) const {
    if (frames.empty()) {
        return kCMTimeInvalid;
    }
    auto it = std::upper_bound(frames.begin(), frames.end(), t, less);
    return it == frames.begin() ? frames.front() : *std::prev(it);
}

CMTime SampleTable::keyframeAt(CMTime t) const {
    if (keyframes.empty()) {
        return kCMTimeInvalid;
    }
    auto it = std::upper_bound(keyframes.begin(), keyframes.end(), t, less);
    return it == keyframes.begin() ? keyframes.front() : *std::prev(it);
}

std::vector<std::pair<CMTime, CMTime>> SampleTable::gaps(double atLeastSeconds) const {
    std::vector<std::pair<CMTime, CMTime>> out;
    for (size_t i = 1; i < frames.size(); ++i) {
        if (CMTimeGetSeconds(CMTimeSubtract(frames[i], frames[i - 1])) >= atLeastSeconds) {
            out.emplace_back(frames[i - 1], frames[i]);
        }
    }
    return out;
}

SampleTable readSampleTable(const std::string &path) {
    SampleTable table;
    @autoreleasepool {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(path.c_str())] options:nil];
        __block NSArray<AVAssetTrack *> *tracks = nil;
        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        [asset loadTracksWithMediaType:AVMediaTypeVideo
                     completionHandler:^(NSArray<AVAssetTrack *> *result, NSError *) {
                         tracks = result;
                         dispatch_semaphore_signal(loaded);
                     }];
        dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
        AVAssetTrack *track = tracks.firstObject;
        if (track == nil) {
            return table;
        }
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (reader == nil) {
            return table;
        }
        // Passthrough: sample timing and sync flags without decoding.
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
        output.alwaysCopiesSampleData = NO;
        [reader addOutput:output];
        if (![reader startReading]) {
            return table;
        }
        while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
            // Marker buffers (no data) are not frames; the decoders skip them too.
            if (CMSampleBufferGetDataBuffer(sample) != nullptr && CMSampleBufferGetNumSamples(sample) > 0) {
                const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
                if (CMTIME_IS_NUMERIC(pts)) {
                    table.frames.push_back(pts);
                    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
                    bool sync = true;
                    if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
                        auto dict = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
                        CFBooleanRef notSync =
                            static_cast<CFBooleanRef>(CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync));
                        sync = notSync == nullptr || !CFBooleanGetValue(notSync);
                    }
                    if (sync) {
                        table.keyframes.push_back(pts);
                    }
                }
            }
            CFRelease(sample);
        }
        const CMTimeRange range = track.timeRange;
        table.trackEnd = CMTimeRangeGetEnd(range);
    }
    std::sort(table.frames.begin(), table.frames.end(), less);
    table.frames.erase(std::unique(table.frames.begin(), table.frames.end(),
                                   [](CMTime a, CMTime b) { return CMTimeCompare(a, b) == 0; }),
                       table.frames.end());
    std::sort(table.keyframes.begin(), table.keyframes.end(), less);
    return table;
}

// MARK: - SeekRig

SeekRig::SeekRig(const Project &model, SequenceId sequence, Options options) : project(model), sequenceId(sequence) {
    router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    cache = std::make_shared<media::FrameCache>(options.cacheBudgetBytes);
    media::DecodePool::Config poolConfig;
    poolConfig.budgetFraction = options.poolBudgetFraction;
    pool = std::make_shared<media::DecodePool>(router, cache, poolConfig);

    playback::PlaybackConfig config;
    config.scrubLaneBase = 0; // the program controller's (VEEngine kProgramLaneBase)
    config.powerSource = std::make_shared<audio::ManualPowerSource>(false);
    config.makeOutput = [](audio::AudioMixer &mixer) -> std::unique_ptr<audio::IAudioOutput> {
        audio::NullAudioOutputConfig c;
        c.mode = audio::NullAudioOutputConfig::Mode::Realtime;
        return std::make_unique<audio::NullAudioOutput>(mixer, c);
    };
    if (options.adjust) {
        options.adjust(config);
    }
    controller = std::make_unique<PlaybackController>(router, cache, pool, config);
    source_ = controller->frameSource();

    auto tc = render::TextureCache::create(MTLCreateSystemDefaultDevice());
    if (tc.ok()) {
        textures_ = std::move(tc).value();
    } else {
        error_ = tc.error().description();
        return;
    }

    for (const MediaAsset &asset : project.assets) {
        if (!asset.hasVideo() || asset.isStill()) {
            continue;
        }
        const std::string path = playback::mediaPathForURL(asset.url);
        SampleTable table = readSampleTable(path);
        if (table.empty()) {
            error_ = "no video samples in " + path;
            return;
        }
        tables.emplace(asset.id, std::move(table));
    }

    queue_ = dispatch_queue_create("framewright.tests.seekrig.render", DISPATCH_QUEUE_SERIAL);
    playback::PlaybackObserver observer;
    observer.needsDisplay = [this] {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++redrawRequests_;
        }
        render();
    };
    controller->setObserver(queue_, std::move(observer));
    controller->setSequence(std::make_shared<const Project>(project), sequenceId);
}

SeekRig::~SeekRig() {
    if (controller) {
        controller->setObserver(nil, {});
    }
    if (queue_ != nil) {
        releaseRedraws();
        dispatch_sync(queue_, ^{
                      }); // drain the redraws already queued (they use this object)
    }
    source_ = nullptr;
    controller.reset();
}

void SeekRig::publishEdit() {
    controller->modelChanged(std::make_shared<const Project>(project));
}

void SeekRig::render() {
    render::PreviewFrameRequest request;
    request.isRenderOnce = true;
    request.textureCache = &textures_;
    source_(request, frame_);
    const PresentedFrame presented = controller->lastPresented();
    std::lock_guard<std::mutex> lock(mutex_);
    ++renders_;
    if (presented.serial != presented_.serial || presented.heldBackFrameIndex != presented_.heldBackFrameIndex) {
        presentedAt_ = std::chrono::steady_clock::now();
    }
    presented_ = presented;
}

void SeekRig::holdRedraws() {
    if (!held_) {
        held_ = true;
        dispatch_suspend(queue_);
    }
}

void SeekRig::releaseRedraws() {
    if (held_) {
        held_ = false;
        dispatch_resume(queue_);
    }
}

int SeekRig::redrawRequests() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return redrawRequests_;
}

int SeekRig::renders() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return renders_;
}

std::chrono::steady_clock::time_point SeekRig::click(int64_t frame, std::chrono::milliseconds hold) {
    const Sequence &sequence = *project.findSequence(sequenceId);
    const CMTime t = CMTimeMultiply(sequence.frameDuration, static_cast<int32_t>(frame));
    baseline_.redrawRequests = redrawRequests();
    baseline_.renders = renders();
    baseline_.cache = cache->stats();
    baseline_.pool = pool->stats();
    const auto clickedAt = std::chrono::steady_clock::now();
    controller->scrubTo(t);
    if (hold.count() > 0) {
        std::this_thread::sleep_for(hold);
    }
    controller->endScrub();
    return clickedAt;
}

std::vector<SeekRig::ExpectedLayer> SeekRig::expected(int64_t frame) const {
    const Sequence &sequence = *project.findSequence(sequenceId);
    const CMTime t = CMTimeMultiply(sequence.frameDuration, static_cast<int32_t>(frame));
    std::vector<ExpectedLayer> out;
    for (const VideoLayer &layer : Scheduler::renderGraphAt(sequence, project, t).layers) {
        ExpectedLayer e;
        e.clip = layer.clipId;
        e.asset = layer.assetId;
        if (const MediaAsset *asset = project.findAsset(layer.assetId)) {
            e.pictureTime = playback::pictureTimeFor(layer, *asset);
            if (auto table = tables.find(layer.assetId); table != tables.end()) {
                e.pts = table->second.frameAt(e.pictureTime);
            }
        }
        out.push_back(e);
    }
    return out;
}

SeekRig::Outcome SeekRig::check(int64_t frame, std::chrono::steady_clock::time_point clickedAt,
                                std::chrono::milliseconds timeout) {
    const std::vector<ExpectedLayer> want = expected(frame);
    const int redrawsBefore = baseline_.redrawRequests;
    const int rendersBefore = baseline_.renders;
    const media::FrameCache::Stats &cacheBefore = baseline_.cache;
    const media::DecodePool::Stats &poolBefore = baseline_.pool;

    auto matches = [&](const PresentedFrame &p) {
        if (p.frameIndex != frame || p.heldBackFrameIndex >= 0 || p.layers.size() != want.size()) {
            return false;
        }
        for (size_t i = 0; i < want.size(); ++i) {
            const PresentedLayer &l = p.layers[i];
            if (l.clip != want[i].clip || !l.exact || CMTimeCompare(l.shownPts, want[i].pts) != 0) {
                return false;
            }
        }
        return true;
    };

    const auto deadline = clickedAt + timeout;
    Outcome outcome;
    PresentedFrame last;
    std::chrono::steady_clock::time_point lastAt;
    for (;;) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            last = presented_;
            lastAt = presentedAt_;
        }
        if (matches(last)) {
            outcome.shown = true;
            outcome.latencyMs =
                std::chrono::duration<double, std::milli>(std::max(lastAt, clickedAt) - clickedAt).count();
            return outcome;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }

    // A miss: what the monitor shows, and why.
    outcome.redrawRequests = redrawRequests() - redrawsBefore;
    outcome.renders = renders() - rendersBefore;
    const media::FrameCache::Stats cacheAfter = cache->stats();
    const media::DecodePool::Stats poolAfter = pool->stats();
    const uint64_t settled = poolAfter.scrubServiced + poolAfter.scrubCancelled + poolAfter.scrubFailed;
    const bool scrubPending = poolAfter.scrubRequests > settled;
    if (last.frameIndex != frame) {
        if (last.heldBackFrameIndex == frame) {
            outcome.category = scrubPending ? "held back, decode still in flight" : "held back, nothing in flight";
        } else {
            outcome.category = "frame never presented";
        }
    } else if (last.layers.size() != want.size()) {
        outcome.category = "wrong layer count";
    } else {
        bool missing = false;
        for (const PresentedLayer &l : last.layers) {
            missing = missing || !l.exact;
        }
        outcome.category = missing ? "presented without its picture" : "wrong picture";
    }
    std::ostringstream d;
    const Sequence &sequence = *project.findSequence(sequenceId);
    d << "frame " << frame << " (" << secondsText(CMTimeMultiply(sequence.frameDuration, static_cast<int32_t>(frame)))
      << " s): shows frame " << last.frameIndex << " heldBack " << last.heldBackFrameIndex;
    for (size_t i = 0; i < want.size(); ++i) {
        const ExpectedLayer &w = want[i];
        const Clip *clip = sequence.findClip(w.clip);
        const SampleTable *table = tables.count(w.asset) ? &tables.at(w.asset) : nullptr;
        d << "\n  layer " << i << ": clip " << w.clip.value() << " asset " << w.asset.value();
        if (clip) {
            d << " speed " << clip->speed.num << "/" << clip->speed.den;
        }
        d << " picture time " << secondsText(w.pictureTime) << " wants pts " << secondsText(w.pts);
        if (table) {
            d << " (keyframe " << secondsText(table->keyframeAt(w.pictureTime)) << ", "
              << secondsText(CMTimeSubtract(w.pictureTime, table->keyframeAt(w.pictureTime))) << " s after it)";
        }
        d << " cached now " << (cache->contains(w.asset, w.pictureTime) ? "yes" : "no");
        if (i < last.layers.size() && last.frameIndex == frame) {
            const PresentedLayer &l = last.layers[i];
            d << "; shown clip " << l.clip.value() << " exact " << l.exact << " pts " << secondsText(l.shownPts);
        }
    }
    d << "\n  after the click: " << outcome.redrawRequests << " redraw requests, " << outcome.renders
      << " renders; scrub requests " << (poolAfter.scrubRequests - poolBefore.scrubRequests) << " serviced "
      << (poolAfter.scrubServiced - poolBefore.scrubServiced) << " cancelled "
      << (poolAfter.scrubCancelled - poolBefore.scrubCancelled) << " failed "
      << (poolAfter.scrubFailed - poolBefore.scrubFailed) << (scrubPending ? " (one pending)" : "")
      << "; cache evictions " << (cacheAfter.evictions - cacheBefore.evictions) << ", "
      << (cacheAfter.bytes >> 20) << " MB in " << cacheAfter.count << " frames";
    for (const auto &s : poolAfter.streams) {
        d << "\n  stream asset " << s.asset.value() << " lane " << s.lane << " target " << secondsText(s.target)
          << " range [" << secondsText(s.rangeStart) << ", " << secondsText(s.rangeEnd) << ") idle " << s.idle
          << (s.error ? " error " + s.error->description() : "");
    }
    outcome.details = d.str();
    return outcome;
}

} // namespace ve::test
