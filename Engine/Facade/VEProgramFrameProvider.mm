#include "VEProgramFrameProvider+Internal.h"

#import <Foundation/Foundation.h>

#include <map>
#include <utility>

namespace ve::facade {

// One show() request: every layer's buffer, and per asset the layers still to decode (the
// scrub path keeps only the newest request per asset, so layers sharing an asset are decoded
// one after another). Touched on the main thread only.
struct ProgramFrameProvider::Pending {
    uint64_t generation = 0;
    RenderGraph graph;
    std::vector<media::PixelBuffer> buffers;
    std::vector<int> attempts; // per layer: requests made so far
    std::map<AssetId, std::vector<size_t>> queued;
    size_t remaining = 0;
    media::Status status; // first failure
    std::function<void()> onReady;
};

ProgramFrameProvider::ProgramFrameProvider(std::shared_ptr<media::DecodePool> pool, uint64_t laneBase)
    : pool_(std::move(pool)), laneBase_(laneBase), shared_(std::make_shared<Shared>()) {}

render::PreviewFrameSource ProgramFrameProvider::makeSource() const {
    auto shared = shared_;
    return [shared](const render::PreviewFrameRequest &request, render::PreviewFrame &frame) {
        RenderGraph graph;
        std::vector<media::PixelBuffer> buffers;
        media::Status status;
        {
            std::lock_guard<std::mutex> lock(shared->mutex);
            if (!shared->changed) {
                return false;
            }
            shared->changed = false;
            graph = shared->graph;
            buffers = shared->buffers;
            status = shared->status;
        }
        frame.graph = std::move(graph);
        frame.textures.resize(frame.graph.layers.size());
        for (size_t i = 0; i < frame.textures.size(); ++i) {
            frame.textures[i].reset();
            if (i >= buffers.size() || !buffers[i]) {
                continue;
            }
            if (request.textureCache == nullptr) {
                if (status.ok()) {
                    status = media::makeError(media::MediaErrorCode::InvalidState,
                                              "program monitor: the view has no texture cache (Metal unavailable)");
                }
                continue;
            }
            auto textures = request.textureCache->textures(buffers[i]);
            if (textures.ok()) {
                frame.textures[i] = std::move(textures).value();
            } else if (status.ok()) {
                status = std::move(textures).error();
            }
        }
        frame.status = std::move(status);
        return true;
    };
}

void ProgramFrameProvider::cancel() {
    ++generation_;
}

void ProgramFrameProvider::show(RenderGraph graph, std::function<void()> onReady) {
    const uint64_t generation = ++generation_;
    if (graph.layers.empty()) {
        publish(std::move(graph), {}, media::okStatus());
        if (onReady) {
            onReady();
        }
        return;
    }
    auto pending = std::make_shared<Pending>();
    pending->generation = generation;
    pending->buffers.resize(graph.layers.size());
    pending->attempts.assign(graph.layers.size(), 0);
    pending->remaining = graph.layers.size();
    pending->onReady = std::move(onReady);
    for (size_t i = 0; i < graph.layers.size(); ++i) {
        pending->queued[graph.layers[i].assetId].push_back(i);
    }
    pending->graph = std::move(graph);
    // Start the first layer of each asset; deliver() starts the next one.
    std::vector<size_t> first;
    for (auto &[asset, layers] : pending->queued) {
        first.push_back(layers.front());
        layers.erase(layers.begin());
    }
    for (size_t layer : first) {
        request(pending, layer);
    }
}

void ProgramFrameProvider::request(const std::shared_ptr<Pending> &pending, size_t layer) {
    const VideoLayer &l = pending->graph.layers[layer];
    ++pending->attempts[layer];
    std::weak_ptr<ProgramFrameProvider> weakSelf = weak_from_this();
    pool_->requestFrame(l.assetId, l.isStill ? kCMTimeZero : l.sourceTime,
                        [weakSelf, pending, layer](media::Result<media::ScrubFrame> result) {
                            // Scrub thread: hop to the main thread, where Pending lives.
                            auto boxed = std::make_shared<media::Result<media::ScrubFrame>>(std::move(result));
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (auto self = weakSelf.lock()) {
                                    self->deliver(pending, layer, std::move(*boxed));
                                }
                            });
                        },
                        laneBase_ + layer);
}

void ProgramFrameProvider::deliver(const std::shared_ptr<Pending> &pending, size_t layer,
                                   media::Result<media::ScrubFrame> result) {
    if (pending->generation != generation_) {
        return; // superseded by a newer show()
    }
    if (!result.ok() && result.error().code == media::MediaErrorCode::Cancelled &&
        pending->attempts[layer] <= kMaxRerequests) {
        // Another request for the same asset (possibly from another client) replaced ours
        // before it started; this frame is still wanted, so ask again.
        request(pending, layer);
        return;
    }
    if (result.ok()) {
        pending->buffers[layer] = std::move(result).value().image;
    } else if (pending->status.ok()) {
        // The layer stays empty (the compositor skips it); the frame reports why.
        pending->status = std::move(result).error();
    }
    const AssetId asset = pending->graph.layers[layer].assetId;
    auto &next = pending->queued[asset];
    if (!next.empty()) {
        const size_t nextLayer = next.front();
        next.erase(next.begin());
        request(pending, nextLayer);
    }
    if (--pending->remaining == 0) {
        publish(std::move(pending->graph), std::move(pending->buffers), std::move(pending->status));
        if (pending->onReady) {
            pending->onReady();
        }
    }
}

void ProgramFrameProvider::publish(RenderGraph graph, std::vector<media::PixelBuffer> buffers, media::Status status) {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->graph = std::move(graph);
    shared_->buffers = std::move(buffers);
    shared_->status = std::move(status);
    shared_->changed = true;
}

} // namespace ve::facade
