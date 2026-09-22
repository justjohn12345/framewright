// Harness for the playback controller tests: builds projects from the generated burn-in media,
// runs a PlaybackController over a NullAudioOutput (realtime, or manual with a virtual host
// clock for faster-than-real-time runs), and samples its frame source like the preview view
// would, reading the burn-in frame index of every presented layer.
#pragma once

#include "../../Engine/Audio/AudioOutput.h"
#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Model/Project.h"
#include "../../Engine/Playback/PlaybackController.h"
#include "../../Engine/Render/TextureCache.h"

#include <chrono>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve::test {

class PlaybackHarness {
  public:
    enum class Mode {
        Realtime, ///< NullAudioOutput on its own thread, system host clock.
        Manual,   ///< NullAudioOutput driven by renderBlocks(), virtual host clock.
    };

    /// `captureSeconds` of rendered audio are kept (sequence-sample aligned).
    PlaybackHarness(Mode mode, double captureSeconds);
    ~PlaybackHarness();

    bool ok() const { return error_.empty(); }
    const std::string &error() const { return error_; }

    // MARK: Project

    /// Probes a generated media file and adds it as an asset (routing handed to the controller).
    AssetId importAsset(const std::string &file);
    /// A speed-1 clip; times in 30 fps sequence frames, `sourceIn` in source time.
    ClipId addClip(TrackId track, AssetId asset, int64_t startFrame, int64_t durationFrames, CMTime sourceIn);
    void link(ClipId a, ClipId b);
    void addTransition(TrackId track, ClipId from, ClipId to, int64_t frames);
    /// Validation problem, if any.
    std::optional<std::string> problem() const;
    Sequence &sequence() { return *project.findSequence(sequenceId); }
    /// setSequence with a snapshot of `project`.
    void load();
    /// modelChanged with a snapshot of `project`.
    void publishEdit();

    // MARK: Frame source

    struct Sample {
        bool changed = false;
        CMTime clockBefore = kCMTimeInvalid; ///< Clock read just before / after the call.
        CMTime clockAfter = kCMTimeInvalid;
        playback::PresentedFrame presented;
        std::vector<std::optional<int>> burnIns; ///< Per layer of the current frame.
        std::vector<ClipId> clips;
    };
    /// Calls the frame source once (targetTimestamp 0: "now").
    Sample present();
    /// Presents until every layer shows its exact frame (or `timeout`); returns the last sample.
    Sample presentExact(std::chrono::milliseconds timeout = std::chrono::seconds(5));

    /// Expected source frame slot of `clip` at sequence frame `index` (independent of the
    /// scheduler: speed-1 arithmetic on the asset's frame grid).
    int64_t expectedSlot(ClipId clip, int64_t sequenceFrame) const;

    // MARK: Parts

    Project project;
    SequenceId sequenceId;
    TrackId v1, v2, a1;
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> cache;
    std::shared_ptr<media::DecodePool> pool;
    std::shared_ptr<audio::HostClock> host;
    audio::NullAudioOutput *output = nullptr; // owned by the controller
    std::unique_ptr<playback::PlaybackController> controller;

  private:
    std::string error_;
    render::TextureCache textures_;
    render::PreviewFrameSource source_;
    render::PreviewFrame frame_;
};

/// Sequence time of a frame index at 30 fps.
inline CMTime frames30(int64_t n) {
    return CMTimeMake(n, 30);
}

} // namespace ve::test
