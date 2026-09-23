#include "BackendRouter.h"

#include "Apple/AppleBackend.h"

#include <os/log.h>

#include <algorithm>
#include <functional>
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

/// The track corresponding to `track` (of `primary`) as `backend`'s own prober describes it
/// (its numbering, its decodability and hardware measurements), or nullptr when that backend
/// cannot probe the file or lacks the track.
const TrackInfo *mapTrack(ProbeCache &probes, IMediaBackend &backend, const MediaInfo &primary, const TrackInfo &track,
                          std::string &why) {
    if (backend.name() == primary.backend) {
        return &track;
    }
    const Result<MediaInfo> &probe = probes.get(backend);
    if (!probe.ok()) {
        why = backend.name() + " cannot probe the file (" + probe.error().description() + ")";
        return nullptr;
    }
    const TrackInfo *mapped = nthOfKind(probe.value(), track.kind, ordinalOf(primary, track.index));
    if (mapped == nullptr) {
        why = backend.name() + "'s prober reports no matching " + toString(track.kind) + " track";
        return nullptr;
    }
    return mapped;
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

// MARK: - Writers

std::string BackendRouter::writerBackendFor(const EncodeSettings &settings) const {
    const auto backends = snapshot();
    if (auto apple = find(backends, "apple"); apple && apple->canWrite(settings)) {
        return apple->name();
    }
    for (const auto &b : backends) {
        if (b->canWrite(settings)) {
            return b->name();
        }
    }
    return {};
}

Result<RoutedWriter> BackendRouter::makeWriter(const EncodeSettings &settings) const {
    const std::string name = writerBackendFor(settings);
    std::shared_ptr<IMediaBackend> backend = name.empty() ? nullptr : find(snapshot(), name);
    std::unique_ptr<IMediaWriter> writer = backend ? backend->makeWriter() : nullptr;
    if (!writer) {
        std::string what = settings.video ? toString(settings.video->codec) : "";
        if (settings.audio) {
            what += (what.empty() ? "" : " + ") + std::string(toString(settings.audio->codec));
        }
        return makeError(MediaErrorCode::UnsupportedCodec, "no registered backend can write " + what + " in " +
                                                               toString(settings.container));
    }
    return RoutedWriter{std::move(writer), name};
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

    for (const TrackInfo &track : primary->tracks) {
        TrackRoute route;
        route.trackIndex = track.index;
        route.kind = track.kind;
        route.codec = track.codec.fourCC;
        const MediaInfo sub = singleTrack(*primary, track);
        std::string notes;
        auto note = [&](const std::string &text) { notes += (notes.empty() ? "" : "; ") + text; };
        bool chosenHardware = false;

        // A backend is chosen only if its own prober found the track decodable (a VideoToolbox
        // session for Apple, an opened decoder and a first frame for FFmpeg).
        auto choose = [&](IMediaBackend &b, const std::string &why) -> bool {
            std::string mapWhy;
            const TrackInfo *mapped = mapTrack(probes, b, *primary, track, mapWhy);
            if (mapped == nullptr) {
                note(mapWhy);
                return false;
            }
            if (!mapped->decodable) {
                note(b.name() + " probed it as not decodable");
                return false;
            }
            route.backend = b.name();
            route.backendTrackIndex = mapped->index;
            route.reason = why;
            chosenHardware = mapped->kind == TrackKind::Video && mapped->hardwareDecode;
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
            std::string mapWhy;
            const TrackInfo *appleTrack =
                appleProbe.ok() ? mapTrack(probes, *apple, *primary, track, mapWhy) : nullptr;
            if (!appleProbe.ok()) {
                note("apple cannot probe the file");
            } else if (!apple->canHandle(sub)) {
                note("apple cannot decode " + codecDisplayName(track.codec.fourCC) + " in " + primary->container);
            } else if (appleTrack == nullptr) {
                note(mapWhy);
            } else if (!appleTrack->decodable) {
                note("VideoToolbox/AVFoundation refuse this " + codecDisplayName(track.codec.fourCC) + " stream");
            } else if (track.kind == TrackKind::Video && !appleTrack->hardwareDecode) {
                note(codecDisplayName(track.codec.fourCC) + " does not decode in VideoToolbox hardware here");
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
            route.hardwareDecode = policy.allowHardware && chosenHardware;
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

/// Errors after which another backend may do better: the stream or codec is the problem, not
/// the caller (InvalidArgument/InvalidState), the file system, or an interrupt (Cancelled).
bool worthFallingBack(const MediaError &e) {
    switch (e.code) {
    case MediaErrorCode::UnsupportedCodec:
    case MediaErrorCode::UnsupportedFormat:
    case MediaErrorCode::DecodeFailed:
    case MediaErrorCode::CorruptData:
    case MediaErrorCode::Internal:
        return true;
    default:
        return false;
    }
}

/// Opens a track through the route's backend and, on failure, its fallbacks in order. Kept by
/// the fallback decoders so they can move to the next backend at run time.
template <class Decoder, class Options> class RoutedOpener {
  public:
    using MakeFn = std::function<std::unique_ptr<Decoder>(IMediaBackend &)>;
    struct Opened {
        std::unique_ptr<Decoder> decoder;
        std::string backend;
        int backendTrackIndex = -1;
        size_t attempt = 0;
    };

    RoutedOpener(BackendList backends, std::shared_ptr<const RoutedMediaInfo> routed, TrackRoute route,
                 Options options, MakeFn make)
        : backends_(std::move(backends)), routed_(std::move(routed)), route_(std::move(route)),
          options_(std::move(options)), make_(std::move(make)), probes_(routed_->info.path) {
        attempts_.push_back(route_.backend);
        attempts_.insert(attempts_.end(), route_.fallbacks.begin(), route_.fallbacks.end());
        log_ = route_.reason;
    }

    const std::string &path() const { return routed_->info.path; }
    int trackIndex() const { return route_.trackIndex; }
    const std::string &log() const { return log_; }
    void note(const std::string &text) { log_ += "; " + text; }
    bool hasAttemptAfter(size_t attempt) const { return attempt + 1 < attempts_.size(); }

    /// Opens the first attempt at or after `from` that succeeds.
    Result<Opened> openFrom(size_t from) {
        const TrackInfo *track = routed_->info.track(route_.trackIndex);
        if (route_.backend.empty() || track == nullptr) {
            return makeError(MediaErrorCode::UnsupportedCodec,
                             "track " + std::to_string(route_.trackIndex) + " is not decodable: " + route_.reason);
        }
        std::optional<MediaError> firstError;
        for (size_t i = from; i < attempts_.size(); ++i) {
            const std::string &name = attempts_[i];
            std::shared_ptr<IMediaBackend> backend;
            for (const auto &b : backends_) {
                if (b->name() == name) {
                    backend = b;
                }
            }
            if (!backend) {
                note(name + " is no longer registered");
                continue;
            }
            int index = route_.backendTrackIndex;
            if (i > 0) {
                std::string why;
                const TrackInfo *mapped = mapTrack(probes_, *backend, routed_->info, *track, why);
                if (mapped == nullptr) {
                    note("fallback " + why);
                    continue;
                }
                index = mapped->index;
            }
            std::unique_ptr<Decoder> decoder = make_(*backend);
            if (!decoder) {
                note(name + " provides no decoder");
                continue;
            }
            Status s = decoder->open(routed_->info.path, index, options_);
            if (s.ok()) {
                if (i > 0) {
                    note("fell back to " + name);
                    os_log_error(routerLog(), "%{public}s track %d: %{public}s", routed_->info.path.c_str(),
                                 route_.trackIndex, log_.c_str());
                }
                return Opened{std::move(decoder), name, index, i};
            }
            if (s.error().code == MediaErrorCode::Cancelled) {
                // Interrupted by the owner (DecodeOptions::interrupt): not the backend's fault, and
                // the owner no longer wants this decoder, so no fallback either.
                return s.error();
            }
            note(name + " open failed: " + s.error().description());
            if (!firstError) {
                firstError = s.error();
            }
        }
        MediaError error = firstError ? *firstError : makeError(MediaErrorCode::UnsupportedCodec, "");
        error.message =
            "cannot open track " + std::to_string(route_.trackIndex) + " of " + routed_->info.path + ": " + log_;
        os_log_error(routerLog(), "%{public}s", error.message.c_str());
        return error;
    }

  private:
    BackendList backends_;
    std::shared_ptr<const RoutedMediaInfo> routed_;
    TrackRoute route_;
    Options options_;
    MakeFn make_;
    ProbeCache probes_;
    std::vector<std::string> attempts_;
    std::string log_;
};

using VideoOpener = RoutedOpener<IVideoDecoder, DecodeOptions>;
using AudioOpener = RoutedOpener<IAudioDecoder, AudioOptions>;

/// A video decoder that moves to the route's next backend when the current one fails to
/// decode (an error worthFallingBack() accepts, from seek() or next()), resuming at the time
/// the caller had reached: VideoToolbox can accept a format at open and still refuse samples
/// later (a lazily created random-access session, a mid-stream parameter-set change). Each
/// backend is tried at most once. Returned by BackendRouter::makeVideoDecoder already open.
class FallbackVideoDecoder final : public IVideoDecoder {
  public:
    FallbackVideoDecoder(std::unique_ptr<VideoOpener> opener, VideoOpener::Opened opened)
        : opener_(std::move(opener)), current_(std::move(opened)) {}

    Status open(const std::string &, int, const DecodeOptions &) override {
        return makeError(MediaErrorCode::InvalidState, "a routed decoder is returned open");
    }
    Status seek(CMTime t) override {
        resumeAt_ = t;
        while (true) {
            Status s = current_.decoder->seek(t);
            if (s.ok() || !worthFallingBack(s.error()) || !switchBackend(s.error())) {
                return s;
            }
        }
    }
    Result<std::optional<VideoFrame>> next() override {
        while (true) {
            auto r = current_.decoder->next();
            if (r.ok()) {
                if (r.value()) {
                    const VideoFrame &f = *r.value();
                    resumeAt_ = CMTIME_IS_NUMERIC(f.duration) ? CMTimeAdd(f.pts, f.duration) : f.pts;
                }
                return r;
            }
            if (!worthFallingBack(r.error()) || !switchBackend(r.error())) {
                return r;
            }
            if (CMTIME_IS_NUMERIC(resumeAt_)) {
                Status s = current_.decoder->seek(resumeAt_);
                if (!s.ok()) {
                    return std::move(s).error();
                }
            }
        }
    }
    CMTime frameDuration() const override { return current_.decoder->frameDuration(); }
    bool supportsRandomAccess() const override { return current_.decoder->supportsRandomAccess(); }
    bool usedHardware() const override { return current_.decoder->usedHardware(); }
    OSType outputPixelFormat() const override { return current_.decoder->outputPixelFormat(); }
    std::string activeBackend() const override { return current_.backend; }

  private:
    /// Replaces the current decoder with the next backend's; false when none is left.
    bool switchBackend(const MediaError &error) {
        if (!opener_->hasAttemptAfter(current_.attempt)) {
            return false;
        }
        opener_->note(current_.backend + " failed while decoding: " + error.description());
        auto next = opener_->openFrom(current_.attempt + 1);
        if (!next.ok()) {
            return false;
        }
        os_log_error(routerLog(), "%{public}s track %d: switched from %{public}s to %{public}s at run time",
                     opener_->path().c_str(), opener_->trackIndex(), current_.backend.c_str(),
                     next.value().backend.c_str());
        current_ = std::move(next).value();
        return true;
    }

    std::unique_ptr<VideoOpener> opener_;
    VideoOpener::Opened current_;
    CMTime resumeAt_ = kCMTimeInvalid;
};

/// The audio counterpart of FallbackVideoDecoder: resumes at the current sample position.
class FallbackAudioDecoder final : public IAudioDecoder {
  public:
    FallbackAudioDecoder(std::unique_ptr<AudioOpener> opener, AudioOpener::Opened opened)
        : opener_(std::move(opener)), current_(std::move(opened)) {}

    Status open(const std::string &, int, const AudioOptions &) override {
        return makeError(MediaErrorCode::InvalidState, "a routed decoder is returned open");
    }
    Status seek(CMTime t) override {
        while (true) {
            Status s = current_.decoder->seek(t);
            if (s.ok() || !worthFallingBack(s.error()) || !switchBackend(s.error(), false)) {
                return s;
            }
        }
    }
    Result<int> read(float *interleaved, int frames) override {
        while (true) {
            auto r = current_.decoder->read(interleaved, frames);
            if (r.ok() || !worthFallingBack(r.error())) {
                return r;
            }
            if (!switchBackend(r.error(), true)) {
                return r;
            }
        }
    }
    int64_t position() const override { return current_.decoder->position(); }
    CMTime positionTime() const override { return current_.decoder->positionTime(); }
    double sampleRate() const override { return current_.decoder->sampleRate(); }
    int channels() const override { return current_.decoder->channels(); }
    int64_t lengthFrames() const override { return current_.decoder->lengthFrames(); }
    CMTime seekTolerance() const override { return current_.decoder->seekTolerance(); }
    std::string activeBackend() const override { return current_.backend; }

  private:
    bool switchBackend(const MediaError &error, bool resume) {
        if (!opener_->hasAttemptAfter(current_.attempt)) {
            return false;
        }
        const CMTime position = current_.decoder->positionTime();
        opener_->note(current_.backend + " failed while decoding: " + error.description());
        auto next = opener_->openFrom(current_.attempt + 1);
        if (!next.ok()) {
            return false;
        }
        os_log_error(routerLog(), "%{public}s track %d: switched from %{public}s to %{public}s at run time",
                     opener_->path().c_str(), opener_->trackIndex(), current_.backend.c_str(),
                     next.value().backend.c_str());
        current_ = std::move(next).value();
        if (resume && CMTIME_IS_NUMERIC(position) && !current_.decoder->seek(position).ok()) {
            return false;
        }
        return true;
    }

    std::unique_ptr<AudioOpener> opener_;
    AudioOpener::Opened current_;
};

template <class Decoder, class Options, class Fallback>
Result<RoutedDecoder<Decoder>> openRouted(const BackendList &backends, const RoutedMediaInfo &routed,
                                          const TrackRoute &route, const Options &options,
                                          typename RoutedOpener<Decoder, Options>::MakeFn make) {
    auto opener = std::make_unique<RoutedOpener<Decoder, Options>>(
        backends, std::make_shared<const RoutedMediaInfo>(routed), route, options, std::move(make));
    auto opened = opener->openFrom(0);
    if (!opened.ok()) {
        return std::move(opened).error();
    }
    RoutedDecoder<Decoder> result;
    result.backend = opened.value().backend;
    result.backendTrackIndex = opened.value().backendTrackIndex;
    result.fellBack = opened.value().attempt > 0;
    result.reason = opener->log();
    if (opener->hasAttemptAfter(opened.value().attempt)) {
        result.decoder = std::make_unique<Fallback>(std::move(opener), std::move(opened).value());
    } else {
        result.decoder = std::move(opened.value().decoder);
    }
    return result;
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
    return openRouted<IVideoDecoder, DecodeOptions, FallbackVideoDecoder>(
        snapshot(), routed, *route, effective, [](IMediaBackend &b) { return b.makeVideoDecoder(); });
}

Result<RoutedAudioDecoder> BackendRouter::makeAudioDecoder(const RoutedMediaInfo &routed, int trackIndex,
                                                           const AudioOptions &options) const {
    const TrackRoute *route = trackIndex < 0 ? routed.firstRoute(TrackKind::Audio) : routed.route(trackIndex);
    if (route == nullptr || route->kind != TrackKind::Audio) {
        return makeError(MediaErrorCode::NoSuchTrack,
                         "no audio track " + std::to_string(trackIndex) + " in " + routed.info.path);
    }
    return openRouted<IAudioDecoder, AudioOptions, FallbackAudioDecoder>(
        snapshot(), routed, *route, options, [](IMediaBackend &b) { return b.makeAudioDecoder(); });
}

} // namespace ve::media
