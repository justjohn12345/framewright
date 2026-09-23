// OfflineAudioRenderer: a sequence's audio mix rendered faster than real time, sample-accurately,
// for export.
//
// It is the render thread of a private AudioMixer, so the file gets exactly the mix playback
// plays: the same plans from Scheduler::audioGraphFor, the same per-sample gain, fade and
// constant-power crossfade envelopes, the same speed resampling (ClipAudioSource), the same
// output clipping. Nothing of the mixing is re-implemented here. What differs from playback:
// - Before each block it waits until every source sounding in the block has decoded it
//   (AudioMixer::isRangeReady), so the mixer never underruns. An underrun would be a gap of
//   silence in the file; should one happen anyway it is reported as an error, never written.
// - A source whose decoder failed would play silence; here it is an error naming the asset.
// - Plans cover `planSeconds` ahead of the render position and are renewed when less than
//   `replanMarginSeconds` remain (the playback controller plans a 5 s horizon every second). A
//   renewed plan of the running transport blends envelopes over the mixer's 5 ms ramp, which is
//   an identity here: both plans describe the same clips, so their envelopes agree sample for
//   sample where they overlap.
//
// Sample n of the output is sequence time n / sampleRate, from 0 to totalFrames() (the sequence
// duration at the output rate, rounded to the nearest sample).
//
// Threading: render() from one thread at a time (it may migrate, like a decoder); the other
// accessors from any thread. The destructor stops the sources (joining their decoder threads).
#pragma once

#include "../Media/BackendRouter.h"
#include "../Model/Project.h"
#include "AudioMixer.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>

namespace ve::audio {

class OfflineAudioRenderer {
  public:
    struct Config {
        double sampleRate = 48000.0;
        int channels = 2;
        double planSeconds = 10.0;
        double replanMarginSeconds = 2.0;
        /// Longest wait for the sources of one block to decode it (then Timeout).
        std::chrono::milliseconds stallTimeout{30000};
    };

    /// `routing` (optional per asset) saves a probe per source, like AudioMixer::registerAsset.
    OfflineAudioRenderer(std::shared_ptr<media::BackendRouter> router, std::shared_ptr<const Project> project,
                         SequenceId sequenceId, std::map<AssetId, media::RoutedMediaInfo> routing, Config config);
    ~OfflineAudioRenderer();
    OfflineAudioRenderer(const OfflineAudioRenderer &) = delete;
    OfflineAudioRenderer &operator=(const OfflineAudioRenderer &) = delete;

    double sampleRate() const { return config_.sampleRate; }
    int channels() const { return config_.channels; }
    /// Frames the whole mix has.
    int64_t totalFrames() const { return total_; }
    /// Next frame render() produces.
    int64_t position() const { return position_.load(std::memory_order_acquire); }

    /// Renders up to `maxFrames` interleaved frames into `dst`; returns the number rendered, 0 at
    /// the end. Errors: Cancelled when `cancelled()` returns true while waiting for decoded audio;
    /// DecodeFailed when the decoder of a clip sounding in the block failed (the message names the
    /// asset); Timeout when the sources did not decode the block within Config::stallTimeout;
    /// Internal if the mixer underran regardless.
    media::Result<int> render(float *dst, int maxFrames, const std::function<bool()> &cancelled);

  private:
    void plan(int64_t from);

    const std::shared_ptr<const Project> project_;
    const SequenceId sequenceId_;
    const Config config_;
    std::unique_ptr<AudioMixer> mixer_;
    int64_t total_ = 0;
    int64_t plannedUntil_ = -1; // sequence sample the newest plan reaches (-1: none yet)
    bool started_ = false;
    std::atomic<int64_t> position_{0};
};

} // namespace ve::audio
