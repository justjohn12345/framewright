// BackendRouter: decides which IMediaBackend probes and decodes each track of an asset.
//
// Rules (PLAN.md, "Media backend abstraction"), applied per track:
//  0. RoutingPolicy::preferBackendName, when that backend is registered and accepts the track
//     (IMediaBackend::canHandle), wins. Otherwise the override is ignored and the reason says so.
//  1. The Apple fast path: the backend named "apple" is chosen when its prober succeeded, it
//     accepts the track, its prober found the track decodable, and the track is audio, a
//     still, or video that its prober measured as hardware decoded (a VTDecompressionSession
//     for the track's format reported UsingHardwareAcceleratedVideoDecoder).
//  2. Otherwise the first registered backend (registration order) that accepts the track and
//     whose own prober found it decodable (TrackInfo::decodable).
// Every choice (including 0) requires the chosen backend's prober to report the track
// decodable: AVFoundation, for one, loads MPEG-4 Part 2 ASP and calls it decodable, but
// VideoToolbox refuses the stream, which the Apple prober detects and FFmpeg decodes.
// A track no backend accepts is reported as unroutable (TrackRoute::backend empty); probe()
// fails only when no backend can probe the file at all or no track is routable.
//
// Track indices: TrackInfo::index is backend specific. RoutedMediaInfo::info is the probe of
// ONE backend (the first in candidate order whose prober succeeded; see RoutedMediaInfo), and
// each TrackRoute maps a track of `info` to the index of the same track in the chosen
// backend's own numbering (tracks of one kind are matched by ordinal: the n-th video track of
// one prober is the n-th video track of another).
//
// Threading: every method is thread-safe. probe() and make*Decoder() block on I/O (they call
// probers and decoder open()); never call them on the main thread or the audio render thread.
// Registration and policy changes take effect for calls that start afterwards.
#pragma once

#include "Interfaces.h"

#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace ve::media {

/// Per-call (or global default) routing overrides.
struct RoutingPolicy {
    /// Use this backend ("apple", "ffmpeg") for every track it can handle.
    std::optional<std::string> preferBackendName;
    /// When false, decoders are opened with DecodeOptions::allowHardware = false and no route
    /// reports hardware decode.
    bool allowHardware = true;

    bool operator==(const RoutingPolicy &) const = default;
};

/// The decision for one track of RoutedMediaInfo::info.
struct TrackRoute {
    int trackIndex = -1; ///< TrackInfo::index in RoutedMediaInfo::info.
    TrackKind kind = TrackKind::Video;
    uint32_t codec = 0;
    /// Chosen backend name; empty if no registered backend accepts the track.
    std::string backend;
    /// TrackInfo::index of this track in the chosen backend's numbering (== trackIndex when the
    /// chosen backend also produced `info`).
    int backendTrackIndex = -1;
    /// Whether decoding runs on VideoToolbox hardware, as measured by the chosen backend's prober
    /// (video only; audio and stills decode on the CPU and report false). False when the policy
    /// disallows hardware.
    bool hardwareDecode = false;
    /// Other backends that accept the track, in the order decoders fall back to them.
    std::vector<std::string> fallbacks;
    /// Why this backend was chosen (and why others were not).
    std::string reason;
};

struct RoutedMediaInfo {
    /// Probe result of the first backend (candidate order: preferred, "apple", then
    /// registration order) whose prober succeeded. info.backend names it.
    MediaInfo info;
    /// One route per track of `info`, in the same order.
    std::vector<TrackRoute> routes;
    /// The policy the decision was made under (decoders opened from this info follow it).
    RoutingPolicy policy;
    /// Human-readable summary of every decision, including probe failures, one line each.
    std::string reason;

    /// Route of a track of `info` (by TrackInfo::index), or nullptr.
    const TrackRoute *route(int trackIndex) const;
    /// Route of the first track of `kind`, or nullptr.
    const TrackRoute *firstRoute(TrackKind kind) const;
    /// Route of the first video track, else the first still, else nullptr.
    const TrackRoute *visualRoute() const;
    /// Backend chosen for the first track of `kind` ("" if none).
    std::string backendFor(TrackKind kind) const;
};

/// A decoder opened through the router plus the details of how it was obtained.
template <class Decoder> struct RoutedDecoder {
    std::unique_ptr<Decoder> decoder;
    std::string backend;         ///< Backend that opened it.
    int backendTrackIndex = -1;  ///< Track index in that backend's numbering.
    bool fellBack = false;       ///< True if the routed backend failed to open and another did.
    std::string reason;          ///< The route's reason plus any fallback attempts.
};
using RoutedVideoDecoder = RoutedDecoder<IVideoDecoder>;
using RoutedAudioDecoder = RoutedDecoder<IAudioDecoder>;

class BackendRouter {
  public:
    BackendRouter() = default;
    BackendRouter(const BackendRouter &) = delete;
    BackendRouter &operator=(const BackendRouter &) = delete;

    /// A router with the Apple backend registered.
    static std::shared_ptr<BackendRouter> makeDefault();

    /// Appends a backend (lower priority than those registered before it). Registering a name
    /// twice replaces the earlier backend in place. Returns InvalidArgument for nullptr or an
    /// empty name.
    Status registerBackend(std::shared_ptr<IMediaBackend> backend);
    /// Removes the backend named `name`; false if none was registered.
    bool unregisterBackend(const std::string &name);
    /// Registered backend names in priority order.
    std::vector<std::string> backendNames() const;
    std::shared_ptr<IMediaBackend> backend(const std::string &name) const;

    /// Default policy used by probe(path) (the app's "Prefer FFmpeg for decode" setting).
    void setDefaultPolicy(RoutingPolicy policy);
    RoutingPolicy defaultPolicy() const;

    /// Probes `path` and routes every track. Errors: InvalidState if no backend is registered;
    /// the most specific prober error (FileNotFound, PermissionDenied, CorruptData, ...) if no
    /// prober accepts the file, UnsupportedCodec if no backend can decode any track. The
    /// error message lists every backend's answer.
    Result<RoutedMediaInfo> probe(const std::string &path) const;
    Result<RoutedMediaInfo> probe(const std::string &path, const RoutingPolicy &policy) const;

    /// Opens a video (or still) decoder for `trackIndex` of routed.info (-1: the first video
    /// track, else the first still) through the routed backend. If open() fails the route's
    /// fallbacks are tried in order and the attempt is recorded in the returned reason. When
    /// routed.policy.allowHardware is false, options.allowHardware is forced false.
    /// Run-time fallback: while untried fallbacks remain, the returned decoder is a wrapper that
    /// switches to the next backend when seek()/next() fails with UnsupportedCodec,
    /// UnsupportedFormat, DecodeFailed, CorruptData or Internal, re-seeking the new decoder to
    /// where the caller was (the end of the last delivered frame, or the last seek target).
    /// It is returned already open (calling open() on it is InvalidState);
    /// IVideoDecoder::activeBackend() names the backend currently decoding.
    Result<RoutedVideoDecoder> makeVideoDecoder(const RoutedMediaInfo &routed, int trackIndex,
                                                const DecodeOptions &options) const;
    /// Same for audio (-1: the first audio track); the audio wrapper resumes at the sample
    /// position read() had reached.
    Result<RoutedAudioDecoder> makeAudioDecoder(const RoutedMediaInfo &routed, int trackIndex,
                                                const AudioOptions &options) const;

  private:
    std::vector<std::shared_ptr<IMediaBackend>> snapshot() const;
    std::shared_ptr<IMediaBackend> find(const std::vector<std::shared_ptr<IMediaBackend>> &backends,
                                        const std::string &name) const;

    mutable std::mutex mutex_;
    std::vector<std::shared_ptr<IMediaBackend>> backends_;
    RoutingPolicy defaultPolicy_;
};

} // namespace ve::media
