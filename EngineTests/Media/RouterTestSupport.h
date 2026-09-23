// Test doubles for the router, decode pool and thumbnail tests: a scriptable IMediaBackend
// whose video decoder synthesises burn-in frames (readable with BurnIn.h), with hooks to
// slow down, gate or observe decoding. Plus small synchronisation helpers.
#pragma once

#include "../../Engine/Media/Interfaces.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace ve::test {

/// Behaviour of a FakeBackend. Shared (by pointer) between the backend and its decoders so
/// tests can change it and read counters while decoders run.
struct FakeBehavior {
    std::string name = "fake";
    /// Probe result; default: UnsupportedFormat.
    std::function<media::Result<media::MediaInfo>(const std::string &path)> probe;
    /// canHandle answer; default: true for every info.
    std::function<bool(const media::MediaInfo &)> canHandle;
    /// Make open() of video/audio decoders fail with DecodeFailed.
    bool failOpen = false;
    /// Called at the start of every video decoder open() (may block: used as a gate).
    std::function<void()> onOpen;
    /// next() fails with `failCode` instead of producing any frame at or after `failAtFrame`
    /// (-1: never).
    int64_t failAtFrame = -1;
    media::MediaErrorCode failCode = media::MediaErrorCode::DecodeFailed;
    /// Audio read() fails with DecodeFailed once the position reaches this sample (-1: never).
    int64_t failAudioAtSample = -1;
    /// Poll DecodeOptions::interrupt at the start of next() and again after onDecode (the
    /// simulated decode work): an interrupted call returns Cancelled like the real decoders.
    bool honorInterrupt = true;

    // Synthetic video.
    int frames = 300;
    CMTime frameDuration = CMTimeMake(1, 30);
    int width = 288; ///< Multiple of 18 keeps the burn-in cells integral.
    int height = 162;
    /// Output format. Only 32BGRA frames carry a burn-in; others (e.g. 4K 'x420' for budget
    /// tests) are identified by their pts.
    OSType pixelFormat = kCVPixelFormatType_32BGRA;
    std::chrono::microseconds decodeDelay{0}; ///< Sleep per next() (simulated decode cost).
    /// Called in next() before producing frame `index` (may block: used as a gate).
    std::function<void(int64_t index)> onDecode;
    /// Called at the start of every seek (may block: used as a gate).
    std::function<void(CMTime)> onSeek;

    // Observations.
    std::atomic<int> opens{0};
    std::atomic<int> liveDecoders{0};
    std::atomic<int> seeks{0};
    std::atomic<int> framesDecoded{0};
    std::atomic<int> interrupted{0}; ///< next() calls that returned Cancelled.
    std::atomic<int> probes{0};
    std::mutex mutex; ///< Guards the fields below.
    std::vector<int> openedTrackIndices;
    std::vector<bool> openedAllowHardware;
};

class FakeBackend final : public media::IMediaBackend {
  public:
    explicit FakeBackend(std::shared_ptr<FakeBehavior> behavior) : b_(std::move(behavior)) {}
    std::string name() const override { return b_->name; }
    std::unique_ptr<media::IMediaProber> makeProber() override;
    std::unique_ptr<media::IVideoDecoder> makeVideoDecoder() override;
    std::unique_ptr<media::IAudioDecoder> makeAudioDecoder() override;
    std::unique_ptr<media::IMediaWriter> makeWriter() override { return nullptr; }
    bool canHandle(const media::MediaInfo &info) const override { return b_->canHandle ? b_->canHandle(info) : true; }
    bool canWrite(const media::EncodeSettings &) const override { return false; }

  private:
    std::shared_ptr<FakeBehavior> b_;
};

/// A MediaInfo with one video track (index `videoIndex`, codec `videoCodec`) and optionally one
/// audio track (index videoIndex + 1), matching FakeBehavior's default synthetic video. The
/// video track's TrackInfo::hardwareDecode is what HardwareCaps says for the codec (what a real
/// prober measures on this machine for an ordinary stream of it); decodable is true.
media::MediaInfo makeFakeInfo(const std::string &path, const std::string &container, uint32_t videoCodec,
                              bool withAudio = true, int videoIndex = 0, const std::string &backend = "fake");

/// Counts down to zero; wait() blocks until then or timeout.
class Latch {
  public:
    explicit Latch(int count) : count_(count) {}
    void countDown() {
        std::lock_guard<std::mutex> lock(m_);
        if (--count_ <= 0) {
            cv_.notify_all();
        }
    }
    bool wait(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(m_);
        return cv_.wait_for(lock, timeout, [&] { return count_ <= 0; });
    }

  private:
    std::mutex m_;
    std::condition_variable cv_;
    int count_;
};

/// A one-shot gate: pass() blocks until open() (or the timeout, to keep a broken test from
/// hanging forever).
class Gate {
  public:
    void open() {
        std::lock_guard<std::mutex> lock(m_);
        open_ = true;
        cv_.notify_all();
    }
    bool pass(std::chrono::milliseconds timeout = std::chrono::seconds(10)) {
        std::unique_lock<std::mutex> lock(m_);
        return cv_.wait_for(lock, timeout, [&] { return open_; });
    }

  private:
    std::mutex m_;
    std::condition_variable cv_;
    bool open_ = false;
};

} // namespace ve::test
