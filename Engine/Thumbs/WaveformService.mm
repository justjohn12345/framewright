#include "WaveformService.h"

#include "CacheKey.h"

#include <Accelerate/Accelerate.h>
#include <os/log.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iterator>

namespace ve::thumbs {

using namespace ve::media;

namespace {

os_log_t waveLog() {
    static os_log_t log = os_log_create("ve.thumbs", "waveform");
    return log;
}

constexpr char kMagic[4] = {'V', 'E', 'W', 'F'};
constexpr int kChunkBuckets = 32;
constexpr double kProgressStep = 0.05;

// MARK: Little-endian serialisation

class Writer {
  public:
    void u32(uint32_t v) { le(v, 4); }
    void u64(uint64_t v) { le(v, 8); }
    void i64(int64_t v) { le(static_cast<uint64_t>(v), 8); }
    void f32(float v) { le(std::bit_cast<uint32_t>(v), 4); }
    void f64(double v) { le(std::bit_cast<uint64_t>(v), 8); }
    void raw(const char *p, size_t n) { bytes.insert(bytes.end(), p, p + n); }
    std::vector<uint8_t> bytes;

  private:
    void le(uint64_t v, int n) {
        for (int i = 0; i < n; ++i) {
            bytes.push_back(static_cast<uint8_t>(v >> (8 * i)));
        }
    }
};

class Reader {
  public:
    Reader(const uint8_t *p, size_t n) : p_(p), n_(n) {}
    bool u32(uint32_t &v) { return le(v, 4); }
    bool u64(uint64_t &v) { return le(v, 8); }
    bool i64(int64_t &v) {
        uint64_t u = 0;
        const bool ok = le(u, 8);
        v = static_cast<int64_t>(u);
        return ok;
    }
    bool f32(float &v) {
        uint32_t u = 0;
        const bool ok = le(u, 4);
        v = std::bit_cast<float>(u);
        return ok;
    }
    bool f64(double &v) {
        uint64_t u = 0;
        const bool ok = le(u, 8);
        v = std::bit_cast<double>(u);
        return ok;
    }
    bool raw(char *dst, size_t n) {
        if (n_ - pos_ < n) {
            return false;
        }
        std::memcpy(dst, p_ + pos_, n);
        pos_ += n;
        return true;
    }
    size_t remaining() const { return n_ - pos_; }

  private:
    template <class T> bool le(T &v, int n) {
        if (n_ - pos_ < static_cast<size_t>(n)) {
            return false;
        }
        uint64_t x = 0;
        for (int i = 0; i < n; ++i) {
            x |= static_cast<uint64_t>(p_[pos_ + i]) << (8 * i);
        }
        pos_ += n;
        v = static_cast<T>(x);
        return true;
    }
    const uint8_t *p_;
    size_t n_;
    size_t pos_ = 0;
};

MediaError cancelledError() {
    return makeError(MediaErrorCode::Cancelled, "waveform request cancelled");
}

} // namespace

// MARK: - WaveformPeaks and file format

int WaveformPeaks::samplesPerBucket() const {
    return bucketsPerSecond == 0 ? 0 : static_cast<int>(std::lround(sampleRate / bucketsPerSecond));
}

size_t WaveformPeaks::bucketAt(double seconds) const {
    if (mono.empty() || !(seconds > 0)) {
        return 0;
    }
    const auto b = static_cast<size_t>(std::floor(seconds * bucketsPerSecond));
    return std::min(b, mono.size() - 1);
}

Status writeWaveformFile(const std::string &path, const WaveformPeaks &peaks, const WaveformSource &source) {
    if (peaks.perChannel.size() != peaks.channels) {
        return makeError(MediaErrorCode::InvalidArgument, "waveform channel count mismatch");
    }
    Writer w;
    w.raw(kMagic, 4);
    w.u32(WaveformPeaks::kFormatVersion);
    w.u64(source.size);
    w.i64(source.modifiedNanoseconds);
    w.f64(peaks.sampleRate);
    w.u32(peaks.bucketsPerSecond);
    w.u32(peaks.channels);
    w.u64(peaks.mono.size());
    auto emit = [&](const std::vector<PeakBucket> &buckets) {
        for (const PeakBucket &b : buckets) {
            w.f32(b.min);
            w.f32(b.max);
        }
    };
    emit(peaks.mono);
    for (const auto &channel : peaks.perChannel) {
        if (channel.size() != peaks.mono.size()) {
            return makeError(MediaErrorCode::InvalidArgument, "waveform bucket count mismatch");
        }
        emit(channel);
    }
    return writeFileAtomically(path, w.bytes.data(), w.bytes.size());
}

Result<WaveformPeaks> readWaveformFile(const std::string &path, const WaveformSource *expected) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return makeError(MediaErrorCode::FileNotFound, "no waveform file " + path);
    }
    const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    Reader r(bytes.data(), bytes.size());
    char magic[4] = {};
    uint32_t version = 0;
    WaveformSource source;
    WaveformPeaks peaks;
    uint64_t count = 0;
    if (!r.raw(magic, 4) || std::memcmp(magic, kMagic, 4) != 0 || !r.u32(version)) {
        return makeError(MediaErrorCode::CorruptData, "not a waveform file: " + path);
    }
    if (version != WaveformPeaks::kFormatVersion) {
        return makeError(MediaErrorCode::UnsupportedFormat,
                         "waveform file version " + std::to_string(version) + " in " + path);
    }
    if (!r.u64(source.size) || !r.i64(source.modifiedNanoseconds) || !r.f64(peaks.sampleRate) ||
        !r.u32(peaks.bucketsPerSecond) || !r.u32(peaks.channels) || !r.u64(count)) {
        return makeError(MediaErrorCode::CorruptData, "truncated waveform header: " + path);
    }
    if (peaks.channels > 64 || count > r.remaining() / 8 ||
        r.remaining() != count * 8 * (1 + static_cast<uint64_t>(peaks.channels))) {
        return makeError(MediaErrorCode::CorruptData, "waveform file size does not match its header: " + path);
    }
    if (expected && (expected->size != source.size || expected->modifiedNanoseconds != source.modifiedNanoseconds)) {
        return makeError(MediaErrorCode::InvalidState, "waveform file is for another version of the source: " + path);
    }
    auto readBuckets = [&](std::vector<PeakBucket> &out) {
        out.resize(count);
        for (PeakBucket &b : out) {
            (void)r.f32(b.min);
            (void)r.f32(b.max);
        }
    };
    readBuckets(peaks.mono);
    peaks.perChannel.resize(peaks.channels);
    for (auto &channel : peaks.perChannel) {
        readBuckets(channel);
    }
    return peaks;
}

// MARK: - Service

WaveformService::WaveformService(std::shared_ptr<BackendRouter> router, Config config)
    : router_(std::move(router)), config_(std::move(config)) {
    if (!config_.diskCacheDirectory.empty()) {
        disk_ = std::make_unique<DiskCacheBudget>(config_.diskCacheDirectory, ".vewf", config_.diskBudgetBytes);
    }
    const int n = std::max(1, config_.threads);
    for (int i = 0; i < n; ++i) {
        threads_.emplace_back([this] { workerMain(); });
    }
}

WaveformService::~WaveformService() {
    std::vector<Listener> cancelled;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        for (auto &[key, job] : jobs_) {
            job->cancelled = true;
            for (auto &l : job->listeners) {
                cancelled.push_back(std::move(l));
            }
            job->listeners.clear();
        }
        queue_.clear();
        stats_.cancelled += cancelled.size();
    }
    cv_.notify_all();
    complete(std::move(cancelled), cancelledError());
    for (std::thread &t : threads_) {
        t.join();
    }
}

void WaveformService::complete(std::vector<Listener> listeners, const WaveformResult &result) {
    for (Listener &l : listeners) {
        WaveformCallback callback = std::move(l.completion);
        WaveformResult copy = result;
        dispatch_async(l.queue, ^{
          callback(copy);
        });
    }
}

std::string WaveformService::diskFileName(const WaveformRequest &request) const {
    const FileIdentity id = fileIdentity(request.url);
    Hasher h;
    h.add(std::string_view("ve.waveform"))
        .add(static_cast<uint64_t>(WaveformPeaks::kFormatVersion))
        .add(request.url)
        .add(id.size)
        .add(id.modifiedNanoseconds)
        .add(static_cast<int64_t>(request.trackIndex))
        .add(static_cast<uint64_t>(config_.bucketsPerSecond))
        .add(std::bit_cast<uint64_t>(config_.sampleRate));
    return h.hex() + ".vewf";
}

WaveformService::RequestId WaveformService::request(const WaveformRequest &request, dispatch_queue_t queue,
                                                    WaveformCallback completion, WaveformProgress progress) {
    if (!completion) {
        return 0;
    }
    if (queue == nullptr) {
        queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        complete({Listener{0, queue, std::move(completion), {}}},
                 makeError(MediaErrorCode::InvalidArgument, "waveform request without a callback queue"));
        return 0;
    }
    const double perBucket = config_.bucketsPerSecond ? config_.sampleRate / config_.bucketsPerSecond : 0;
    if (request.url.empty() || perBucket < 1 || perBucket != std::floor(perBucket)) {
        complete({Listener{0, queue, std::move(completion), {}}},
                 makeError(MediaErrorCode::InvalidArgument,
                           "waveform request needs a path and a sample rate that is a multiple of the bucket rate"));
        return 0;
    }
    const Key key{request.asset, request.trackIndex};
    const FileIdentity identity = fileIdentity(request.url);
    std::unique_lock<std::mutex> lock(mutex_);
    ++stats_.requests;
    const RequestId id = nextId_++;
    if (stopping_) {
        ++stats_.cancelled;
        lock.unlock();
        complete({Listener{id, queue, std::move(completion), {}}}, cancelledError());
        return id;
    }
    if (auto it = memory_.find(key); it != memory_.end()) {
        const MemoryEntry &e = it->second;
        if (e.url == request.url && e.fileSize == identity.size && e.fileModified == identity.modifiedNanoseconds) {
            ++stats_.memoryHits;
            auto peaks = e.peaks;
            lock.unlock();
            complete({Listener{id, queue, std::move(completion), {}}}, peaks);
            return id;
        }
        memory_.erase(it); // Relinked or changed on disk: recompute.
    }
    Listener listener{id, queue, std::move(completion), std::move(progress)};
    if (auto it = jobs_.find(key); it != jobs_.end() && !it->second->cancelled) {
        it->second->listeners.push_back(std::move(listener));
        return id;
    }
    auto job = std::make_shared<Job>();
    job->key = key;
    job->request = request;
    job->listeners.push_back(std::move(listener));
    jobs_[key] = job;
    queue_.push_back(std::move(job));
    lock.unlock();
    cv_.notify_one();
    return id;
}

bool WaveformService::cancel(RequestId id) {
    std::vector<Listener> cancelled;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = jobs_.begin(); it != jobs_.end() && cancelled.empty(); ++it) {
            Job &job = *it->second;
            auto l = std::find_if(job.listeners.begin(), job.listeners.end(),
                                  [&](const Listener &x) { return x.id == id; });
            if (l == job.listeners.end()) {
                continue;
            }
            cancelled.push_back(std::move(*l));
            job.listeners.erase(l);
            if (job.listeners.empty()) {
                job.cancelled = true;
                if (!job.started) {
                    queue_.erase(std::find(queue_.begin(), queue_.end(), it->second));
                    jobs_.erase(it);
                }
            }
            ++stats_.cancelled;
            break;
        }
    }
    if (cancelled.empty()) {
        return false;
    }
    complete(std::move(cancelled), cancelledError());
    return true;
}

std::shared_ptr<const WaveformPeaks> WaveformService::cached(AssetId asset, int trackIndex) const {
    std::string url;
    uint64_t size = 0;
    int64_t modified = 0;
    std::shared_ptr<const WaveformPeaks> peaks;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = memory_.find(Key{asset, trackIndex});
        if (it == memory_.end()) {
            return nullptr;
        }
        url = it->second.url;
        size = it->second.fileSize;
        modified = it->second.fileModified;
        peaks = it->second.peaks;
    }
    const FileIdentity now = fileIdentity(url); // Outside the lock: a stat.
    return now.size == size && now.modifiedNanoseconds == modified ? peaks : nullptr;
}

void WaveformService::purge(AssetId asset) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = memory_.begin(); it != memory_.end();) {
        it = it->first.asset == asset ? memory_.erase(it) : std::next(it);
    }
}

WaveformService::Stats WaveformService::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

void WaveformService::workerMain() {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        cv_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
        if (stopping_) {
            return;
        }
        std::shared_ptr<Job> job = std::move(queue_.front());
        queue_.pop_front();
        job->started = true;
        lock.unlock();

        // std::thread workers have no autorelease pool: drain what decoding autoreleases.
        @autoreleasepool {
            const FileIdentity identity = fileIdentity(job->request.url);
            bool fromDisk = false;
            WaveformResult result = produce(*job, fromDisk);

            lock.lock();
            auto it = jobs_.find(job->key);
            if (it != jobs_.end() && it->second == job) {
                jobs_.erase(it);
            }
            std::vector<Listener> listeners = std::move(job->listeners);
            job->listeners.clear();
            if (result.ok()) {
                memory_[job->key] =
                    MemoryEntry{result.value(), job->request.url, identity.size, identity.modifiedNanoseconds};
                ++(fromDisk ? stats_.diskHits : stats_.computed);
            } else if (result.error().code != MediaErrorCode::Cancelled) {
                ++stats_.failures;
            }
            lock.unlock();
            complete(std::move(listeners), result);
        }
        lock.lock();
    }
}

WaveformResult WaveformService::produce(Job &job, bool &fromDisk) {
    const FileIdentity id = fileIdentity(job.request.url);
    const WaveformSource source{id.size, id.modifiedNanoseconds};
    std::string diskPath;
    if (!config_.diskCacheDirectory.empty()) {
        diskPath = config_.diskCacheDirectory + "/" + diskFileName(job.request);
        auto cachedFile = readWaveformFile(diskPath, &source);
        if (cachedFile.ok() && cachedFile->bucketsPerSecond == config_.bucketsPerSecond &&
            cachedFile->sampleRate == config_.sampleRate) {
            fromDisk = true;
            disk_->touch(diskPath);
            reportProgress(job, 1.0);
            return std::make_shared<const WaveformPeaks>(std::move(cachedFile).value());
        }
    }
    WaveformResult result = compute(job);
    if (result.ok() && !diskPath.empty()) {
        Status st = ensureDirectory(config_.diskCacheDirectory);
        if (st.ok()) {
            st = writeWaveformFile(diskPath, *result.value(), source);
        }
        if (st.ok()) {
            disk_->added(fileIdentity(diskPath).size);
        }
        if (!st.ok()) {
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.diskWriteFailures;
            os_log_error(waveLog(), "waveform disk cache write failed: %{public}s", st.error().description().c_str());
        }
    }
    return result;
}

void WaveformService::reportProgress(Job &job, double fraction) {
    std::vector<std::pair<dispatch_queue_t, WaveformProgress>> targets;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const Listener &l : job.listeners) {
            if (l.progress) {
                targets.emplace_back(l.queue, l.progress);
            }
        }
    }
    for (auto &[queue, progress] : targets) {
        WaveformProgress callback = progress;
        dispatch_async(queue, ^{
          callback(fraction);
        });
    }
}

WaveformResult WaveformService::compute(Job &job) {
    auto routed = router_->probe(job.request.url, config_.routing);
    if (!routed.ok()) {
        return std::move(routed).error();
    }
    const RoutedMediaInfo &info = routed.value();
    const TrackRoute *route =
        job.request.trackIndex < 0 ? info.firstRoute(TrackKind::Audio) : info.route(job.request.trackIndex);
    const TrackInfo *track = route ? info.info.track(route->trackIndex) : nullptr;
    if (track == nullptr || track->kind != TrackKind::Audio) {
        return makeError(MediaErrorCode::NoSuchTrack, "no audio track in " + job.request.url);
    }
    AudioOptions options;
    options.sampleRate = config_.sampleRate;
    options.channels = std::clamp(track->channels, 1, 8);
    auto opened = router_->makeAudioDecoder(info, route->trackIndex, options);
    if (!opened.ok()) {
        return std::move(opened).error();
    }
    IAudioDecoder &decoder = *opened.value().decoder;

    auto peaks = std::make_shared<WaveformPeaks>();
    peaks->sampleRate = config_.sampleRate;
    peaks->bucketsPerSecond = config_.bucketsPerSecond;
    peaks->channels = static_cast<uint32_t>(decoder.channels());
    const int channels = decoder.channels();
    const int perBucket = peaks->samplesPerBucket();
    const int64_t total = decoder.lengthFrames();
    const size_t expectedBuckets = total > 0 ? static_cast<size_t>((total + perBucket - 1) / perBucket) : 0;
    peaks->mono.reserve(expectedBuckets);
    peaks->perChannel.resize(channels);
    for (auto &c : peaks->perChannel) {
        c.reserve(expectedBuckets);
    }

    const int chunkFrames = perBucket * kChunkBuckets;
    std::vector<float> samples(static_cast<size_t>(chunkFrames) * channels);
    std::vector<float> mono(static_cast<size_t>(chunkFrames));
    const float channelScale = 1.0f / static_cast<float>(channels);
    double lastReported = 0;
    reportProgress(job, 0.0);

    for (;;) {
        if (job.cancelled.load(std::memory_order_relaxed)) {
            return cancelledError();
        }
        auto got = decoder.read(samples.data(), chunkFrames);
        if (!got.ok()) {
            return std::move(got).error();
        }
        const int n = got.value();
        if (n <= 0) {
            break;
        }
        // Mono mix: average of the channels.
        vDSP_vclr(mono.data(), 1, static_cast<vDSP_Length>(n));
        for (int c = 0; c < channels; ++c) {
            vDSP_vsma(samples.data() + c, channels, &channelScale, mono.data(), 1, mono.data(), 1,
                      static_cast<vDSP_Length>(n));
        }
        for (int start = 0; start < n; start += perBucket) {
            const auto len = static_cast<vDSP_Length>(std::min(perBucket, n - start));
            PeakBucket m;
            vDSP_minv(mono.data() + start, 1, &m.min, len);
            vDSP_maxv(mono.data() + start, 1, &m.max, len);
            peaks->mono.push_back(m);
            for (int c = 0; c < channels; ++c) {
                const float *base = samples.data() + static_cast<size_t>(start) * channels + c;
                PeakBucket b;
                vDSP_minv(base, channels, &b.min, len);
                vDSP_maxv(base, channels, &b.max, len);
                peaks->perChannel[c].push_back(b);
            }
        }
        if (total > 0) {
            const double fraction = std::min(1.0, static_cast<double>(decoder.position()) / total);
            if (fraction - lastReported >= kProgressStep) {
                lastReported = fraction;
                reportProgress(job, fraction);
            }
        }
        if (n < chunkFrames) {
            break;
        }
    }
    reportProgress(job, 1.0);
    return std::shared_ptr<const WaveformPeaks>(std::move(peaks));
}

} // namespace ve::thumbs
