#include "AudioTestSupport.h"

#include <algorithm>
#include <cmath>

#include <pthread.h>

using namespace ve::media;

// libmalloc's logging hook (used by MallocStackLogging); exported by libsystem_malloc but not
// declared in a public header.
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
extern "C" malloc_logger_t *malloc_logger;

namespace ve::test {

namespace {

class ToneDecoder final : public IAudioDecoder {
  public:
    explicit ToneDecoder(std::shared_ptr<ToneBehavior> behavior) : b_(std::move(behavior)) {}

    Status open(const std::string &path, int, const AudioOptions &options) override {
        ++b_->opens;
        std::lock_guard<std::mutex> lock(b_->mutex);
        auto it = b_->signals.find(path);
        if (it == b_->signals.end()) {
            return makeError(MediaErrorCode::FileNotFound, "tone: unknown path " + path);
        }
        signal_ = it->second;
        options_ = options;
        return okStatus();
    }
    Status seek(CMTime t) override {
        ++b_->seeks;
        position_ = std::max<int64_t>(0, static_cast<int64_t>(std::floor(CMTimeGetSeconds(t) * options_.sampleRate + 1e-9)));
        return okStatus();
    }
    Result<int> read(float *interleaved, int frames) override {
        if (b_->readAllowed) {
            std::unique_lock<std::mutex> lock(b_->mutex);
            b_->gateCv.wait(lock, [&] { return b_->readAllowed(); });
        }
        const int64_t left = std::max<int64_t>(0, b_->lengthFrames - position_);
        const int n = static_cast<int>(std::min<int64_t>(frames, left));
        for (int k = 0; k < n; ++k) {
            for (int c = 0; c < options_.channels; ++c) {
                interleaved[static_cast<size_t>(k) * options_.channels + c] = signal_(position_ + k, c);
            }
        }
        position_ += n;
        b_->framesRead += n;
        return n;
    }
    int64_t position() const override { return position_; }
    CMTime positionTime() const override { return CMTimeMake(position_, static_cast<int32_t>(options_.sampleRate)); }
    double sampleRate() const override { return options_.sampleRate; }
    int channels() const override { return options_.channels; }
    int64_t lengthFrames() const override { return b_->lengthFrames; }

  private:
    std::shared_ptr<ToneBehavior> b_;
    ToneSignal signal_;
    AudioOptions options_;
    int64_t position_ = 0;
};

class ToneProber final : public IMediaProber {
  public:
    explicit ToneProber(std::shared_ptr<ToneBehavior> behavior) : b_(std::move(behavior)) {}
    Result<MediaInfo> probe(const std::string &path) override {
        std::lock_guard<std::mutex> lock(b_->mutex);
        if (!b_->signals.count(path)) {
            return makeError(MediaErrorCode::FileNotFound, "tone: unknown path " + path);
        }
        MediaInfo info;
        info.path = path;
        info.container = "wav";
        info.backend = "tone";
        info.duration = CMTimeMake(b_->lengthFrames, 48000);
        TrackInfo track;
        track.index = 0;
        track.kind = TrackKind::Audio;
        track.codec = {fourcc::LinearPCM, "PCM"};
        track.sampleRate = 48000;
        track.channels = 2;
        track.duration = info.duration;
        info.tracks.push_back(track);
        return info;
    }

  private:
    std::shared_ptr<ToneBehavior> b_;
};

class ToneBackend final : public IMediaBackend {
  public:
    explicit ToneBackend(std::shared_ptr<ToneBehavior> behavior) : b_(std::move(behavior)) {}
    std::string name() const override { return "tone"; }
    std::unique_ptr<IMediaProber> makeProber() override { return std::make_unique<ToneProber>(b_); }
    std::unique_ptr<IVideoDecoder> makeVideoDecoder() override { return nullptr; }
    std::unique_ptr<IAudioDecoder> makeAudioDecoder() override { return std::make_unique<ToneDecoder>(b_); }
    std::unique_ptr<IMediaWriter> makeWriter() override { return nullptr; }
    bool canHandle(const MediaInfo &) const override { return true; }
    bool canWrite(const EncodeSettings &) const override { return false; }

  private:
    std::shared_ptr<ToneBehavior> b_;
};

// Allocation counting. The counting thread is identified by pthread_self() rather than a
// thread_local: TLV storage in a loadable bundle is allocated lazily by dyld (with calloc),
// which would recurse into the logger on every other thread.
std::atomic<pthread_t> gCountingThread{nullptr};
std::atomic<uint64_t> gAllocations{0};
malloc_logger_t *gPreviousLogger = nullptr;

void countingLogger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                    uint32_t skip) {
    if (gCountingThread.load(std::memory_order_relaxed) == pthread_self()) {
        gAllocations.fetch_add(1, std::memory_order_relaxed);
    }
    if (gPreviousLogger) {
        gPreviousLogger(type, arg1, arg2, arg3, result, skip);
    }
}

} // namespace

std::shared_ptr<BackendRouter> makeToneRouter(std::shared_ptr<ToneBehavior> behavior) {
    auto router = std::make_shared<BackendRouter>();
    (void)router->registerBackend(std::make_shared<ToneBackend>(std::move(behavior)));
    return router;
}

ToneSignal sineSignal(double frequency, double amplitude, double rate) {
    return [=](int64_t n, int) {
        return static_cast<float>(amplitude * std::sin(2.0 * M_PI * frequency * static_cast<double>(n) / rate));
    };
}

ToneSignal constantSignal(float c0, float c1) {
    return [=](int64_t, int channel) { return channel == 0 ? c0 : c1; };
}

AllocationCounter::AllocationCounter() {
    gPreviousLogger = malloc_logger;
    malloc_logger = countingLogger;
}

AllocationCounter::~AllocationCounter() {
    gCountingThread.store(nullptr);
    malloc_logger = gPreviousLogger;
}

void AllocationCounter::start() {
    gAllocations.store(0, std::memory_order_relaxed);
    gCountingThread.store(pthread_self());
}

uint64_t AllocationCounter::stop() {
    gCountingThread.store(nullptr);
    return gAllocations.load(std::memory_order_relaxed);
}

} // namespace ve::test
