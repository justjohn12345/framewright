#include "RouterTestSupport.h"

#include "../../Engine/Media/HardwareCaps.h"
#include "../../Engine/Model/TimeUtil.h"
#include "BurnIn.h"

#include <thread>

namespace ve::test {

using namespace ve::media;

namespace {

class FakeProber final : public IMediaProber {
  public:
    explicit FakeProber(std::shared_ptr<FakeBehavior> b) : b_(std::move(b)) {}
    Result<MediaInfo> probe(const std::string &path) override {
        ++b_->probes;
        if (!b_->probe) {
            return makeError(MediaErrorCode::UnsupportedFormat, b_->name + " does not know " + path);
        }
        return b_->probe(path);
    }

  private:
    std::shared_ptr<FakeBehavior> b_;
};

class FakeVideoDecoder final : public IVideoDecoder {
  public:
    explicit FakeVideoDecoder(std::shared_ptr<FakeBehavior> b) : b_(std::move(b)) { ++b_->liveDecoders; }
    ~FakeVideoDecoder() override { --b_->liveDecoders; }

    Status open(const std::string &, int trackIndex, const DecodeOptions &options) override {
        ++b_->opens;
        {
            std::lock_guard<std::mutex> lock(b_->mutex);
            b_->openedTrackIndices.push_back(trackIndex);
            b_->openedAllowHardware.push_back(options.allowHardware);
        }
        interrupt_ = options.interrupt;
        if (b_->onOpen) {
            b_->onOpen();
        }
        if (b_->failOpen) {
            return makeError(MediaErrorCode::DecodeFailed, b_->name + ": scripted open failure");
        }
        auto pool = PixelBufferPool::create(b_->pixelFormat, b_->width, b_->height);
        if (!pool.ok()) {
            return std::move(pool).error();
        }
        pool_ = std::move(pool).value();
        opened_ = true;
        return okStatus();
    }
    Status seek(CMTime t) override {
        ++b_->seeks;
        if (b_->onSeek) {
            b_->onSeek(t);
        }
        position_ = std::max<int64_t>(0, frameIndexAt(t, b_->frameDuration, SnapMode::Floor));
        return okStatus();
    }
    Result<std::optional<VideoFrame>> next() override {
        if (!opened_) {
            return makeError(MediaErrorCode::InvalidState, "not open");
        }
        if (position_ >= b_->frames) {
            return std::optional<VideoFrame>();
        }
        if (interrupted()) {
            return cancelled();
        }
        const int64_t index = position_;
        if (b_->failAtFrame >= 0 && index >= b_->failAtFrame) {
            return makeError(b_->failCode, b_->name + ": scripted decode failure at frame " + std::to_string(index));
        }
        if (b_->onDecode) {
            b_->onDecode(index);
        }
        if (b_->decodeDelay.count() > 0) {
            std::this_thread::sleep_for(b_->decodeDelay);
        }
        if (interrupted()) {
            return cancelled(); // Abandoned mid-decode: position unchanged, resumable.
        }
        ++position_;
        auto image = pool_.makeBuffer();
        if (!image.ok()) {
            return std::move(image).error();
        }
        if (b_->pixelFormat == kCVPixelFormatType_32BGRA) {
            drawBurnIn(image->get(), static_cast<int>(index));
        }
        ++b_->framesDecoded;
        VideoFrame f;
        f.pts = timeForFrame(index, b_->frameDuration);
        f.duration = b_->frameDuration;
        f.image = std::move(image).value();
        return std::optional<VideoFrame>(std::move(f));
    }
    CMTime frameDuration() const override { return b_->frameDuration; }
    bool supportsRandomAccess() const override { return true; }
    bool usedHardware() const override { return false; }
    OSType outputPixelFormat() const override { return b_->pixelFormat; }

  private:
    bool interrupted() const { return b_->honorInterrupt && interrupt_ && interrupt_->requested(); }
    Result<std::optional<VideoFrame>> cancelled() {
        ++b_->interrupted;
        return makeError(MediaErrorCode::Cancelled, b_->name + ": interrupted");
    }

    std::shared_ptr<FakeBehavior> b_;
    std::shared_ptr<DecodeInterrupt> interrupt_;
    PixelBufferPool pool_;
    bool opened_ = false;
    int64_t position_ = 0;
};

class FakeAudioDecoder final : public IAudioDecoder {
  public:
    explicit FakeAudioDecoder(std::shared_ptr<FakeBehavior> b) : b_(std::move(b)) {}
    Status open(const std::string &, int trackIndex, const AudioOptions &options) override {
        ++b_->opens;
        {
            std::lock_guard<std::mutex> lock(b_->mutex);
            b_->openedTrackIndices.push_back(trackIndex);
        }
        if (b_->failOpen) {
            return makeError(MediaErrorCode::DecodeFailed, b_->name + ": scripted open failure");
        }
        options_ = options;
        return okStatus();
    }
    Status seek(CMTime t) override {
        position_ = std::max<int64_t>(0, static_cast<int64_t>(CMTimeGetSeconds(t) * options_.sampleRate));
        return okStatus();
    }
    Result<int> read(float *interleaved, int frames) override {
        if (b_->failAudioAtSample >= 0 && position_ >= b_->failAudioAtSample) {
            return makeError(MediaErrorCode::DecodeFailed, b_->name + ": scripted audio failure");
        }
        const int64_t left = std::max<int64_t>(0, lengthFrames() - position_);
        const int n = static_cast<int>(std::min<int64_t>(frames, left));
        std::fill(interleaved, interleaved + static_cast<size_t>(n) * options_.channels, 0.0f);
        position_ += n;
        return n;
    }
    int64_t position() const override { return position_; }
    CMTime positionTime() const override { return CMTimeMake(position_, static_cast<int32_t>(options_.sampleRate)); }
    double sampleRate() const override { return options_.sampleRate; }
    int channels() const override { return options_.channels; }
    int64_t lengthFrames() const override {
        return static_cast<int64_t>(CMTimeGetSeconds(CMTimeMultiply(b_->frameDuration, b_->frames)) *
                                    options_.sampleRate);
    }

  private:
    std::shared_ptr<FakeBehavior> b_;
    AudioOptions options_;
    int64_t position_ = 0;
};

} // namespace

std::unique_ptr<IMediaProber> FakeBackend::makeProber() {
    return std::make_unique<FakeProber>(b_);
}

std::unique_ptr<IVideoDecoder> FakeBackend::makeVideoDecoder() {
    return std::make_unique<FakeVideoDecoder>(b_);
}

std::unique_ptr<IAudioDecoder> FakeBackend::makeAudioDecoder() {
    return std::make_unique<FakeAudioDecoder>(b_);
}

MediaInfo makeFakeInfo(const std::string &path, const std::string &container, uint32_t videoCodec, bool withAudio,
                       int videoIndex, const std::string &backend) {
    MediaInfo info;
    info.path = path;
    info.container = container;
    info.backend = backend;
    info.duration = CMTimeMake(10, 1);
    TrackInfo v;
    v.index = videoIndex;
    v.kind = TrackKind::Video;
    v.codec = {videoCodec, codecDisplayName(videoCodec)};
    v.width = 288;
    v.height = 162;
    v.frameDuration = CMTimeMake(1, 30);
    v.nominalFps = 30;
    v.duration = CMTimeMake(10, 1);
    // What a real prober would measure on this machine for such a stream.
    v.hardwareDecode = HardwareCaps::get().hardwareDecode(videoCodec);
    info.tracks.push_back(v);
    if (withAudio) {
        TrackInfo a;
        a.index = videoIndex + 1;
        a.kind = TrackKind::Audio;
        a.codec = {fourcc::AAC, "AAC"};
        a.sampleRate = 48000;
        a.channels = 2;
        a.duration = CMTimeMake(10, 1);
        info.tracks.push_back(a);
    }
    return info;
}

} // namespace ve::test
