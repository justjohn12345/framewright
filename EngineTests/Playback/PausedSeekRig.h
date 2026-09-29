// Paused seeks as the program monitor sees them (the "clicking to move the playhead the program output
// doesn't update" report). A PlaybackController over the app's decode configuration (the program
// pool's budget share, lane base 0, the default 512 MB frame cache unless a test scales it) whose frame
// source is called only when the controller asks for a redraw (needsDisplay), on one serial queue: the
// paused program view does exactly that (its display link is stopped; -[VEEngine observeController:]
// turns needsDisplay into -[VEPreviewView renderOnce]). A test that polled the frame source itself would
// hide a picture that lands without a redraw request.
//
// SeekRig::click() is the ruler click (-[ProjectStore scrub(toSeconds:)] on mouse down, endScrub() on
// mouse up). SeekRig::check() waits (bounded) until the monitor shows the frame the Scheduler resolves
// for the time with every layer's exact picture: the source frame whose display interval contains the
// layer's picture time (playback::pictureTimeFor), taken from the file's own sample table
// (SampleTable, read without decoding), so a wrong cache lookup cannot agree with itself.
#pragma once

#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Model/Project.h"
#include "../../Engine/Playback/PlaybackController.h"
#include "../../Engine/Render/TextureCache.h"

#include <dispatch/dispatch.h>

#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace ve::test {

/// Presentation times of a video file's frames (in presentation order) and of its sync samples.
struct SampleTable {
    std::vector<CMTime> frames;
    std::vector<CMTime> keyframes;
    CMTime trackEnd = kCMTimeInvalid;

    bool empty() const { return frames.empty(); }
    /// pts of the frame shown at `t`: the last frame starting at or before t (the first frame before
    /// it), the IVideoDecoder::seek() rule.
    CMTime frameAt(CMTime t) const;
    /// pts of the last sync sample at or before `t` (the first one before it).
    CMTime keyframeAt(CMTime t) const;
    /// Gaps between consecutive frames longer than `atLeastSeconds`: {pts of the frame before the gap,
    /// pts of the frame after it}.
    std::vector<std::pair<CMTime, CMTime>> gaps(double atLeastSeconds) const;
};

/// Reads the sample table of the first video track of `path` (no decoding). Empty on failure.
SampleTable readSampleTable(const std::string &path);

class SeekRig {
  public:
    struct Options {
        size_t cacheBudgetBytes = media::FrameCache::kDefaultBudgetBytes;
        /// The app's program pool (VEEngine kProgramPoolBudgetShare).
        double poolBudgetFraction = 0.5;
        /// Changes the controller's configuration before it is created (the app's defaults otherwise).
        std::function<void(playback::PlaybackConfig &)> adjust;
    };

    /// Loads `project` (its active sequence) into a new controller. The media paths are the model's.
    SeekRig(const Project &project, SequenceId sequence, Options options);
    ~SeekRig();
    SeekRig(const SeekRig &) = delete;
    SeekRig &operator=(const SeekRig &) = delete;

    bool ok() const { return error_.empty(); }
    const std::string &error() const { return error_; }

    /// The model the controller has (edit it, then publishEdit()).
    Project project;
    const SequenceId sequenceId;
    void publishEdit();

    /// A ruler click at sequence frame `frame`: scrubTo on mouse down, endScrub after `hold`. Returns
    /// the time of the mouse down (what check() measures from); the counters check() reports are
    /// taken from here.
    std::chrono::steady_clock::time_point click(int64_t frame, std::chrono::milliseconds hold);

    /// What the monitor must show for sequence frame `frame`: per layer the clip and the pts of its
    /// picture (from the sample tables).
    struct ExpectedLayer {
        ClipId clip;
        AssetId asset;
        CMTime pictureTime = kCMTimeInvalid;
        CMTime pts = kCMTimeInvalid;
    };
    std::vector<ExpectedLayer> expected(int64_t frame) const;

    /// Outcome of one seek, checked until the monitor shows the frame or `timeout` (from the click).
    struct Outcome {
        bool shown = false;
        double latencyMs = 0; ///< Click to the redraw that showed it (when shown).
        std::string category; ///< Empty when shown; else what was wrong at the deadline.
        std::string details;
        int redrawRequests = 0; ///< needsDisplay after the click.
        int renders = 0;        ///< Frame source calls after the click.
    };
    Outcome check(int64_t frame, std::chrono::steady_clock::time_point clickedAt, std::chrono::milliseconds timeout);

    /// needsDisplay callbacks and frame source calls so far.
    int redrawRequests() const;
    int renders() const;

    /// Holds the redraws the controller asks for (they run, in order, once released): a monitor whose
    /// render thread is busy, or a main queue that is late, so what happens to the cache between the
    /// request and the redraw can be arranged.
    void holdRedraws();
    void releaseRedraws();

    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> cache;
    std::shared_ptr<media::DecodePool> pool;
    std::unique_ptr<playback::PlaybackController> controller;
    std::map<AssetId, SampleTable> tables;

  private:
    void render();

    std::string error_;
    dispatch_queue_t queue_ = nil; ///< The "render thread" (serial): needsDisplay renders here.
    bool held_ = false;            ///< holdRedraws() suspended queue_ (test thread only).
    render::TextureCache textures_;
    render::PreviewFrameSource source_;
    render::PreviewFrame frame_;

    struct Baseline {
        int redrawRequests = 0;
        int renders = 0;
        media::FrameCache::Stats cache;
        media::DecodePool::Stats pool;
    };
    Baseline baseline_; ///< At the latest click (test thread only).

    mutable std::mutex mutex_;
    playback::PresentedFrame presented_; ///< lastPresented() after the latest render.
    std::chrono::steady_clock::time_point presentedAt_{};
    int redrawRequests_ = 0;
    int renders_ = 0;
};

} // namespace ve::test
