#include "BackendRouter.h"

#include "Apple/AppleBackend.h"
#include "HardwareCaps.h"

#include <os/log.h>

#include <algorithm>
#include <map>
#include <sstream>

namespace ve::media {

namespace {

constexpr const char *kAppleName = "apple";

os_log_t routerLog() {
    static os_log_t log = os_log_create("ve.media.router", "routing");
    return log;
}

/// Position of `track` among the tracks of its kind in `info` (0-based), or -1.
int ordinalOf(const MediaInfo &info, int trackIndex) {
    const TrackInfo *track = info.track(trackIndex);
    if (track == nullptr) {
        return -1;
    }
    int n = 0;
    for (const TrackInfo &t : info.tracks) {
        if (t.index == trackIndex) {
            return n;
        }
        if (t.kind == track->kind) {
            ++n;
        }
    }
    return -1;
}

const TrackInfo *nthOfKind(const MediaInfo &info, TrackKind kind, int n) {
    for (const TrackInfo &t : info.tracks) {
        if (t.kind == kind && n-- == 0) {
            return &t;
        }
    }
    return nullptr;
}

/// The same MediaInfo restricted to one track, for per-track canHandle questions.
MediaInfo singleTrack(const MediaInfo &info, const TrackInfo &track) {
    MediaInfo sub;
    sub.path = info.path;
    sub.container = info.container;
    sub.duration = info.duration;
    sub.backend = info.backend;
    sub.tracks = {track};
    return sub;
}

std::string describeTrack(const TrackInfo &t) {
    std::ostringstream s;
    s << "track " << t.index << " " << toString(t.kind) << " " << codecDisplayName(t.codec.fourCC) << " ('"
      << fourCCToString(t.codec.fourCC) << "')";
    return s.str();
}

/// Lower is more informative for the user: a missing file beats "not my format".
int errorSpecificity(MediaErrorCode code) {
    switch (code) {
    case MediaErrorCode::FileNotFound:
    case MediaErrorCode::PermissionDenied:
    case MediaErrorCode::InvalidArgument:
        return 0;
    case MediaErrorCode::CorruptData:
        return 1;
    case MediaErrorCode::UnsupportedFormat:
    case MediaErrorCode::UnsupportedCodec:
        return 3;
    default:
        return 2;
    }
}

using BackendList = std::vector<std::shared_ptr<IMediaBackend>>;

/// Probes each backend at most once per routing decision.
class ProbeCache {
  public:
    explicit ProbeCache(const std::string &path) : path_(path) {}

    const Result<MediaInfo> &get(IMediaBackend &backend) {
        const std::string name = backend.name();
        auto it = results_.find(name);
        if (it == results_.end()) {
            auto prober = backend.makeProber();
            Result<MediaInfo> r = prober ? prober->probe(path_)
                                         : Result<MediaInfo>(makeError(MediaErrorCode::Internal, "no prober"));
            if (r.ok()) {
                r->backend = name;
            }
            it = results_.emplace(name, std::move(r)).first;
        }
        return it->second;
    }

  private:
    std::string path_;
    std::map<std::string, Result<MediaInfo>> results_;
};

/// Candidate order for choosing the primary probe: preferred, apple, then registration order.
BackendList candidateOrder(const BackendList &backends, const RoutingPolicy &policy) {
    BackendList order;
    auto add = [&](const std::shared_ptr<IMediaBackend> &b) {
        if (b && std::find(order.begin(), order.end(), b) == order.end()) {
            order.push_back(b);
        }
    };
    for (const auto &b : backends) {
        if (policy.preferBackendName && b->name() == *policy.preferBackendName) {
            add(b);
        }
    }
    for (const auto &b : backends) {
        if (b->name() == kAppleName) {
            add(b);
        }
    }
    for (const auto &b : backends) {
        add(b);
    }
    return order;
}

/// Index of the track corresponding to `track` (of `primary`) in `backend`'s numbering, or
/// nullopt when that backend cannot probe the file or lacks the track.
std::optional<int> mapTrackIndex(ProbeCache &probes, IMediaBackend &backend, const MediaInfo &primary,
                                 const TrackInfo &track, std::string &why) {
    if (backend.name() == primary.backend) {
        return track.index;
    }
    const Result<MediaInfo> &probe = probes.get(backend);
    if (!probe.ok()) {
        why = backend.name() + " cannot probe the file (" + probe.error().description() + ")";
        return std::nullopt;
    }
    const TrackInfo *mapped = nthOfKind(probe.value(), track.kind, ordinalOf(primary, track.index));
    if (mapped == nullptr) {
        why = backend.name() + "'s prober reports no matching " + toString(track.kind) + " track";
        return std::nullopt;
    }
    return mapped->index;
}

void logRouting(const RoutedMediaInfo &routed) {
    os_log_info(routerLog(), "route %{public}s:\n%{public}s", routed.info.path.c_str(), routed.reason.c_str());
}

} // namespace

// MARK: - RoutedMediaInfo

const TrackRoute *RoutedMediaInfo::route(int trackIndex) const {
    for (const TrackRoute &r : routes) {
        if (r.trackIndex == trackIndex) {
            return &r;
        }
    }
    return nullptr;
}

const TrackRoute *RoutedMediaInfo::firstRoute(TrackKind kind) const {
    for (const TrackRoute &r : routes) {
        if (r.kind == kind) {
            return &r;
        }
    }
    return nullptr;
}

const TrackRoute *RoutedMediaInfo::visualRoute() const {
    if (const TrackRoute *video = firstRoute(TrackKind::Video)) {
        return video;
    }
    return firstRoute(TrackKind::Still);
}

std::string RoutedMediaInfo::backendFor(TrackKind kind) const {
    const TrackRoute *r = firstRoute(kind);
    return r ? r->backend : std::string();
}

// MARK: - Registration

std::shared_ptr<BackendRouter> BackendRouter::makeDefault() {
    auto router = std::make_shared<BackendRouter>();
    (void)router->registerBackend(apple::makeAppleBackend());
    return router;
}

Status BackendRouter::registerBackend(std::shared_ptr<IMediaBackend> backend) {
    if (!backend) {
        return makeError(MediaErrorCode::InvalidArgument, "registerBackend: null backend");
    }
    const std::string name = backend->name();
    if (name.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "registerBackend: backend has an empty name");
    }
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto &existing : backends_) {
        if (existing->name() == name) {
            existing = std::move(backend);
            return okStatus();
        }
    }
    backends_.push_back(std::move(backend));
    os_log_info(routerLog(), "registered backend %{public}s at priority %zu", name.c_str(), backends_.size() - 1);
    return okStatus();
}

bool BackendRouter::unregisterBackend(const std::string &name) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = std::find_if(backends_.begin(), backends_.end(), [&](const auto &b) { return b->name() == name; });
    if (it == backends_.end()) {
        return false;
    }
    backends_.erase(it);
    return true;
}

std::vector<std::string> BackendRouter::backendNames() const {
    std::vector<std::string> names;
    for (const auto &b : snapshot()) {
        names.push_back(b->name());
    }
    return names;
}

std::shared_ptr<IMediaBackend> BackendRouter::backend(const std::string &name) const {
    return find(snapshot(), name);
}

void BackendRouter::setDefaultPolicy(RoutingPolicy policy) {
    std::lock_guard<std::mutex> lock(mutex_);
    defaultPolicy_ = std::move(policy);
}

RoutingPolicy BackendRouter::defaultPolicy() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return defaultPolicy_;
}

std::vector<std::shared_ptr<IMediaBackend>> BackendRouter::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return backends_;
}

std::shared_ptr<IMediaBackend> BackendRouter::find(const std::vector<std::shared_ptr<IMediaBackend>> &backends,
                                                   const std::string &name) const {
    for (const auto &b : backends) {
        if (b->name() == name) {
            return b;
        }
    }
    return nullptr;
}

// MARK: - Probe and route

Result<RoutedMediaInfo> BackendRouter::probe(const std::string &path) const {
    return probe(path, defaultPolicy());
}

Result<RoutedMediaInfo> BackendRouter::probe(const std::string &path, const RoutingPolicy &policy) const {
    const BackendList backends = snapshot();
    if (backends.empty()) {
        return makeError(MediaErrorCode::InvalidState, "no media backend registered");
    }
    const BackendList order = candidateOrder(backends, policy);
    ProbeCache probes(path);
    std::ostringstream reason;

    // Primary probe: first candidate whose prober succeeds.
    const MediaInfo *primary = nullptr;
    std::optional<MediaError> bestError;
    std::string probeFailures;
    for (const auto &b : order) {
        const Result<MediaInfo> &r = probes.get(*b);
        if (r.ok()) {
            primary = &r.value();
            reason << "probe: " << b->name() << " ok (" << r->container << ", " << r->tracks.size() << " tracks)\n";
            break;
        }
        reason << "probe: " << b->name() << " failed: " << r.error().description() << "\n";
        probeFailures += (probeFailures.empty() ? "" : "; ") + b->name() + ": " + r.error().description();
        if (!bestError || errorSpecificity(r.error().code) < errorSpecificity(bestError->code)) {
            bestError = r.error();
        }
    }
    if (primary == nullptr) {
        MediaError error = *bestError;
        error.message = "no backend can open " + path + " (" + probeFailures + ")";
        os_log_error(routerLog(), "%{public}s", error.message.c_str());
        return error;
    }

    RoutedMediaInfo routed;
    routed.info = *primary;
    routed.policy = policy;
    const HardwareCaps &caps = HardwareCaps::get();

    for (const TrackInfo &track : primary->tracks) {
        TrackRoute route;
        route.trackIndex = track.index;
        route.kind = track.kind;
        route.codec = track.codec.fourCC;
        const MediaInfo sub = singleTrack(*primary, track);
        const bool vtHardware = track.kind == TrackKind::Video && caps.hardwareDecode(track.codec.fourCC);
        std::string notes;
        auto note = [&](const std::string &text) { notes += (notes.empty() ? "" : "; ") + text; };

        auto choose = [&](IMediaBackend &b, const std::string &why) -> bool {
            std::string mapWhy;
            auto index = mapTrackIndex(probes, b, *primary, track, mapWhy);
            if (!index) {
                note(mapWhy);
                return false;
            }
            route.backend = b.name();
            route.backendTrackIndex = *index;
            route.reason = why;
            return true;
        };

        // 0. Explicit preference.
        if (policy.preferBackendName) {
            const std::string &want = *policy.preferBackendName;
            auto preferred = find(backends, want);
            if (!preferred) {
                note("preferred backend '" + want + "' is not registered");
            } else if (!preferred->canHandle(sub)) {
                note("preferred backend '" + want + "' cannot decode it");
            } else {
                choose(*preferred, "preferred by policy (" + want + ")");
            }
        }
        // 1. Apple fast path.
        auto apple = find(backends, kAppleName);
        if (route.backend.empty() && apple) {
            const Result<MediaInfo> &appleProbe = probes.get(*apple);
            if (!appleProbe.ok()) {
                note("apple cannot probe the file");
            } else if (!apple->canHandle(sub)) {
                note("apple cannot decode " + codecDisplayName(track.codec.fourCC) + " in " + primary->container);
            } else if (track.kind == TrackKind::Video && !vtHardware) {
                note(codecDisplayName(track.codec.fourCC) + " is not VideoToolbox hardware decodable");
            } else {
                const char *why = track.kind == TrackKind::Video  ? "apple fast path: VideoToolbox hardware decode"
                                  : track.kind == TrackKind::Audio ? "apple fast path: AVFoundation audio"
                                                                   : "apple fast path: ImageIO still";
                choose(*apple, why);
            }
        }
        // 2. First backend that accepts the track.
        if (route.backend.empty()) {
            for (const auto &b : backends) {
                if (!b->canHandle(sub)) {
                    continue;
                }
                if (choose(*b, "first backend accepting it")) {
                    break;
                }
            }
        }
        for (const auto &b : backends) {
            if (b->name() != route.backend && b->canHandle(sub)) {
                route.fallbacks.push_back(b->name());
            }
        }
        if (route.backend.empty()) {
            route.reason = "no backend can decode it";
        } else {
            route.hardwareDecode = policy.allowHardware && vtHardware;
        }
        if (!notes.empty()) {
            route.reason += " (" + notes + ")";
        }
        reason << describeTrack(track) << " -> " << (route.backend.empty() ? "none" : route.backend)
               << (route.hardwareDecode ? " [hw]" : route.backend.empty() ? "" : " [sw]") << ": " << route.reason;
        if (!route.fallbacks.empty()) {
            reason << "; fallbacks:";
            for (const auto &f : route.fallbacks) {
                reason << " " << f;
            }
        }
        reason << "\n";
        routed.routes.push_back(std::move(route));
    }

    routed.reason = reason.str();
    if (!routed.reason.empty() && routed.reason.back() == '\n') {
        routed.reason.pop_back();
    }
    const bool anyRoutable =
        std::any_of(routed.routes.begin(), routed.routes.end(), [](const TrackRoute &r) { return !r.backend.empty(); });
    if (!anyRoutable) {
        os_log_error(routerLog(), "no decodable track in %{public}s:\n%{public}s", path.c_str(),
                     routed.reason.c_str());
        return makeError(MediaErrorCode::UnsupportedCodec, "no backend can decode any track of " + path + ":\n" +
                                                               routed.reason);
    }
    logRouting(routed);
    return routed;
}

// MARK: - Decoders

namespace {

template <class Decoder, class Options, class MakeFn>
Result<RoutedDecoder<Decoder>> openRouted(const BackendList &backends, const RoutedMediaInfo &routed,
                                          const TrackRoute &route, const Options &options, MakeFn make) {
    const TrackInfo *track = routed.info.track(route.trackIndex);
    if (route.backend.empty() || track == nullptr) {
        return makeError(MediaErrorCode::UnsupportedCodec,
                         "track " + std::to_string(route.trackIndex) + " is not decodable: " + route.reason);
    }
    std::vector<std::string> attempts{route.backend};
    attempts.insert(attempts.end(), route.fallbacks.begin(), route.fallbacks.end());

    std::string log = route.reason;
    std::optional<MediaError> firstError;
    ProbeCache probes(routed.info.path);
    for (size_t i = 0; i < attempts.size(); ++i) {
        const std::string &name = attempts[i];
        std::shared_ptr<IMediaBackend> backend;
        for (const auto &b : backends) {
            if (b->name() == name) {
                backend = b;
            }
        }
        if (!backend) {
            log += "; " + name + " is no longer registered";
            continue;
        }
        int index = route.backendTrackIndex;
        if (i > 0) {
            std::string why;
            auto mapped = mapTrackIndex(probes, *backend, routed.info, *track, why);
            if (!mapped) {
                log += "; fallback " + why;
                continue;
            }
            index = *mapped;
        }
        std::unique_ptr<Decoder> decoder = make(*backend);
        if (!decoder) {
            log += "; " + name + " provides no decoder";
            continue;
        }
        Status s = decoder->open(routed.info.path, index, options);
        if (s.ok()) {
            if (i > 0) {
                log += "; fell back to " + name;
                os_log_error(routerLog(), "%{public}s track %d: %{public}s", routed.info.path.c_str(),
                             route.trackIndex, log.c_str());
            }
            RoutedDecoder<Decoder> result;
            result.decoder = std::move(decoder);
            result.backend = name;
            result.backendTrackIndex = index;
            result.fellBack = i > 0;
            result.reason = std::move(log);
            return result;
        }
        log += "; " + name + " open failed: " + s.error().description();
        if (!firstError) {
            firstError = s.error();
        }
    }
    MediaError error = firstError ? *firstError : makeError(MediaErrorCode::UnsupportedCodec, "");
    error.message = "cannot open track " + std::to_string(route.trackIndex) + " of " + routed.info.path + ": " + log;
    os_log_error(routerLog(), "%{public}s", error.message.c_str());
    return error;
}

} // namespace

Result<RoutedVideoDecoder> BackendRouter::makeVideoDecoder(const RoutedMediaInfo &routed, int trackIndex,
                                                           const DecodeOptions &options) const {
    const TrackRoute *route = trackIndex < 0 ? routed.visualRoute() : routed.route(trackIndex);
    if (route == nullptr || route->kind == TrackKind::Audio) {
        return makeError(MediaErrorCode::NoSuchTrack,
                         "no video track " + std::to_string(trackIndex) + " in " + routed.info.path);
    }
    DecodeOptions effective = options;
    if (!routed.policy.allowHardware) {
        effective.allowHardware = false;
    }
    return openRouted<IVideoDecoder>(snapshot(), routed, *route, effective,
                                     [](IMediaBackend &b) { return b.makeVideoDecoder(); });
}

Result<RoutedAudioDecoder> BackendRouter::makeAudioDecoder(const RoutedMediaInfo &routed, int trackIndex,
                                                           const AudioOptions &options) const {
    const TrackRoute *route = trackIndex < 0 ? routed.firstRoute(TrackKind::Audio) : routed.route(trackIndex);
    if (route == nullptr || route->kind != TrackKind::Audio) {
        return makeError(MediaErrorCode::NoSuchTrack,
                         "no audio track " + std::to_string(trackIndex) + " in " + routed.info.path);
    }
    return openRouted<IAudioDecoder>(snapshot(), routed, *route, options,
                                     [](IMediaBackend &b) { return b.makeAudioDecoder(); });
}

} // namespace ve::media
