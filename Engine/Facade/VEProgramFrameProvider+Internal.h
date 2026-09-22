// A still-frame source for the program monitor: shows the sequence frame at one time, decoded
// through DecodePool's scrub path. Used while playback is stopped until the playback controller
// takes over the view (it installs its own PreviewFrameSource).
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#include "../Media/DecodePool.h"
#include "../Render/PreviewFrame.h"
#include "../Render/RenderGraph.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

namespace ve::facade {

class ProgramFrameProvider : public std::enable_shared_from_this<ProgramFrameProvider> {
  public:
    explicit ProgramFrameProvider(std::shared_ptr<media::DecodePool> pool);

    /// The frame source to install on a VEPreviewView (render thread side; never blocks).
    render::PreviewFrameSource makeSource() const;

    /// Main thread. Decodes every layer of `graph` (only the newest call's result is shown) and
    /// then publishes it to the source and calls `onReady` on the main thread. An empty graph
    /// is published immediately (black).
    void show(RenderGraph graph, std::function<void()> onReady);

    /// Main thread: forgets pending work (results of earlier show() calls are dropped).
    void cancel();

  private:
    struct Shared {
        std::mutex mutex;
        RenderGraph graph;
        std::vector<media::PixelBuffer> buffers;
        bool changed = false;
    };
    struct Pending;

    void request(const std::shared_ptr<Pending> &pending, size_t layer);
    void deliver(const std::shared_ptr<Pending> &pending, size_t layer, media::Result<media::ScrubFrame> result);
    void publish(RenderGraph graph, std::vector<media::PixelBuffer> buffers);

    std::shared_ptr<media::DecodePool> pool_;
    std::shared_ptr<Shared> shared_;
    uint64_t generation_ = 0; // main thread only
};

} // namespace ve::facade
