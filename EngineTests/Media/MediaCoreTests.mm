// Backend-independent pieces of the media layer: Result, PixelBuffer ownership,
// ComposedMediaWriter routing, and the burn-in/beep test helpers themselves.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/ComposedMediaWriter.h"
#include "../../Engine/Media/Interfaces.h"
#include "BurnIn.h"

#include <VideoToolbox/VideoToolbox.h>

#include <vector>

// The test target links only the engine framework; these tests call VideoToolbox directly.
asm(".linker_option \"-framework\", \"VideoToolbox\"");

using namespace ve::media;
using namespace ve::test;

namespace {

struct Log {
    std::vector<std::string> events;
    std::vector<EncodedPacket> packets;
};

class FakeVideoEncoder final : public IVideoEncoder {
  public:
    explicit FakeVideoEncoder(Log &log) : log_(log) {}
    Status open(const VideoEncodeSettings &s) override {
        settings_ = s;
        log_.events.push_back("video.open");
        return okStatus();
    }
    Result<EncodedStreamFormat> outputFormat() const override {
        EncodedStreamFormat f;
        f.kind = TrackKind::Video;
        f.codec = codecType(settings_.codec);
        f.width = settings_.width;
        f.height = settings_.height;
        f.frameDuration = settings_.frameDuration;
        f.extradata = {1, 2, 3};
        return f;
    }
    Status encode(const PixelBuffer &frame, CMTime pts, const PacketSink &sink) override {
        // One frame of delay, like an encoder with lookahead.
        if (pending_) {
            VE_MEDIA_TRY(emit(*pending_, sink));
        }
        pending_ = pts;
        return frame ? okStatus() : makeError(MediaErrorCode::InvalidArgument, "no frame");
    }
    Status flush(const PacketSink &sink) override {
        log_.events.push_back("video.flush");
        if (pending_) {
            VE_MEDIA_TRY(emit(*pending_, sink));
            pending_.reset();
        }
        return okStatus();
    }
    bool usesHardware() const override { return true; }

  private:
    Status emit(CMTime pts, const PacketSink &sink) {
        EncodedPacket p;
        p.pts = pts;
        p.dts = pts;
        p.duration = settings_.frameDuration;
        p.isKeyframe = true;
        p.data = {0xAA};
        return sink(std::move(p));
    }
    Log &log_;
    VideoEncodeSettings settings_;
    std::optional<CMTime> pending_;
};

class FakeAudioEncoder final : public IAudioEncoder {
  public:
    explicit FakeAudioEncoder(Log &log) : log_(log) {}
    Status open(const AudioEncodeSettings &s) override {
        settings_ = s;
        log_.events.push_back("audio.open");
        return okStatus();
    }
    Result<EncodedStreamFormat> outputFormat() const override {
        EncodedStreamFormat f;
        f.kind = TrackKind::Audio;
        f.codec = fourcc::AAC;
        f.sampleRate = settings_.sampleRate;
        f.channels = settings_.channels;
        return f;
    }
    Status encode(const float *, int frames, const PacketSink &sink) override {
        buffered_ += frames;
        while (buffered_ >= 1024) { // AAC-style 1024-sample packets.
            EncodedPacket p;
            p.pts = CMTimeMake(emitted_, static_cast<int32_t>(settings_.sampleRate));
            p.dts = p.pts;
            p.duration = CMTimeMake(1024, static_cast<int32_t>(settings_.sampleRate));
            p.data = {0xBB};
            VE_MEDIA_TRY(sink(std::move(p)));
            buffered_ -= 1024;
            emitted_ += 1024;
        }
        return okStatus();
    }
    Status flush(const PacketSink &) override {
        log_.events.push_back("audio.flush");
        return okStatus();
    }

  private:
    Log &log_;
    AudioEncodeSettings settings_;
    int64_t buffered_ = 0;
    int64_t emitted_ = 0;
};

class FakeMuxer final : public IMuxer {
  public:
    explicit FakeMuxer(Log &log) : log_(log) {}
    Status open(const std::string &, ContainerFormat) override {
        log_.events.push_back("mux.open");
        return okStatus();
    }
    Result<int> addStream(const EncodedStreamFormat &f) override {
        log_.events.push_back(f.kind == TrackKind::Video ? "mux.addVideo" : "mux.addAudio");
        return streams_++;
    }
    Status begin() override {
        log_.events.push_back("mux.begin");
        return okStatus();
    }
    Status writePacket(EncodedPacket &&p) override {
        log_.packets.push_back(std::move(p));
        return okStatus();
    }
    Status finish() override {
        log_.events.push_back("mux.finish");
        return okStatus();
    }
    void cancel() override { log_.events.push_back("mux.cancel"); }

  private:
    Log &log_;
    int streams_ = 0;
};

PixelBuffer makeBuffer(OSType format, size_t w, size_t h) {
    auto pool = PixelBufferPool::create(format, w, h);
    if (!pool.ok()) {
        return {};
    }
    auto b = pool->makeBuffer();
    return b.ok() ? std::move(b).value() : PixelBuffer();
}

PixelBuffer convert(const PixelBuffer &src, OSType format, size_t w, size_t h) {
    PixelBuffer dst = makeBuffer(format, w, h);
    VTPixelTransferSessionRef session = nullptr;
    if (!dst || VTPixelTransferSessionCreate(kCFAllocatorDefault, &session) != noErr) {
        return {};
    }
    const OSStatus st = VTPixelTransferSessionTransferImage(session, src.get(), dst.get());
    VTPixelTransferSessionInvalidate(session);
    CFRelease(session);
    return st == noErr ? dst : PixelBuffer();
}

} // namespace

@interface MediaCoreTests : XCTestCase
@end

@implementation MediaCoreTests

- (void)testResultHoldsValueOrError {
    Result<int> good = 5;
    XCTAssertTrue(good.ok());
    XCTAssertEqual(good.value(), 5);
    Result<int> bad = makeError(MediaErrorCode::CorruptData, "broken", "OSStatus", -12909);
    XCTAssertFalse(bad.ok());
    XCTAssertEqual(bad.error().code, MediaErrorCode::CorruptData);
    XCTAssertEqual(bad.error().description(), "CorruptData: broken [OSStatus -12909]");
    Result<std::optional<int>> none = std::nullopt;
    XCTAssertTrue(none.ok());
    XCTAssertFalse(none.value().has_value());
    auto propagate = [](bool fail) -> Result<int> {
        VE_MEDIA_TRY(fail ? Status(makeError(MediaErrorCode::Timeout, "t")) : okStatus());
        return 1;
    };
    XCTAssertEqual(propagate(false).value(), 1);
    XCTAssertEqual(propagate(true).error().code, MediaErrorCode::Timeout);
}

- (void)testPixelBufferOwnership {
    CVPixelBufferRef raw = nullptr;
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nullptr, &raw),
                   kCVReturnSuccess);
    CFRetain(raw); // Our own reference, to observe the count after the wrappers are gone.
    XCTAssertEqual(CFGetRetainCount(raw), 2);
    {
        PixelBuffer a = PixelBuffer::adopt(raw); // Takes the Create reference.
        XCTAssertEqual(CFGetRetainCount(raw), 2);
        PixelBuffer b = a; // Copy retains.
        XCTAssertEqual(CFGetRetainCount(raw), 3);
        PixelBuffer c = std::move(b); // Move does not.
        XCTAssertEqual(CFGetRetainCount(raw), 3);
        XCTAssertFalse(static_cast<bool>(b));
        XCTAssertTrue(c == a);
        PixelBuffer d = PixelBuffer::retain(raw);
        XCTAssertEqual(CFGetRetainCount(raw), 4);
        d = c; // Self-assignment of the same buffer keeps the count balanced.
        XCTAssertEqual(CFGetRetainCount(raw), 4);
        d.reset();
        XCTAssertEqual(CFGetRetainCount(raw), 3);
        XCTAssertEqual(a.width(), 64u);
        XCTAssertEqual(a.height(), 32u);
        XCTAssertEqual(a.pixelFormat(), (OSType)kCVPixelFormatType_32BGRA);
    }
    XCTAssertEqual(CFGetRetainCount(raw), 1, @"every wrapper released its reference");
    CFRelease(raw);

    PixelBuffer pooled = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 128, 72);
    XCTAssertTrue(pooled.isIOSurfaceBacked());
    XCTAssertTrue(PixelBuffer::retainImageBuffer(nullptr) == PixelBuffer());
}

- (void)testBurnInRoundTripsThroughFormatsAndScales {
    for (int index : {0, 1, 0x1234, 0xBEEF, 0xFFFF, 299}) {
        PixelBuffer bgra = makeBuffer(kCVPixelFormatType_32BGRA, 1280, 720);
        XCTAssertTrue(drawBurnIn(bgra.get(), index));
        XCTAssertEqual(readBurnIn(bgra.get()), std::optional<int>(index));
        const OSType formats[] = {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange};
        for (OSType format : formats) {
            for (size_t width : {1280u, 320u}) {
                PixelBuffer yuv = convert(bgra, format, width, width * 9 / 16);
                XCTAssertTrue(static_cast<bool>(yuv));
                XCTAssertEqual(readBurnIn(yuv.get()), std::optional<int>(index), @"format %u width %zu", format, width);
            }
        }
    }
}

- (void)testBurnInRejectsFramesWithoutThePattern {
    PixelBuffer flat = makeBuffer(kCVPixelFormatType_32BGRA, 640, 360);
    {
        PixelBufferLock lock(flat.get(), false);
        memset(CVPixelBufferGetBaseAddress(flat.get()), 0x80, CVPixelBufferGetDataSize(flat.get()));
    }
    XCTAssertFalse(readBurnIn(flat.get()).has_value());
    PixelBuffer black = makeBuffer(kCVPixelFormatType_32BGRA, 640, 360);
    {
        PixelBufferLock lock(black.get(), false);
        memset(CVPixelBufferGetBaseAddress(black.get()), 0, CVPixelBufferGetDataSize(black.get()));
    }
    XCTAssertFalse(readBurnIn(black.get()).has_value(), @"all black must not read as index 0");
    XCTAssertFalse(readBurnIn(nullptr).has_value());
}

- (void)testBeepAndToneHelpers {
    const auto pcm = makeToneWithBeep(440, 48000, 2, 3 * 48000, 2.0);
    auto onset = findBeepOnset(pcm.data(), 3 * 48000, 2, 48000);
    XCTAssertTrue(onset.has_value());
    XCTAssertEqualWithAccuracy(*onset, 2.0, 0.0001);
    XCTAssertEqualWithAccuracy(estimateFrequency(pcm.data(), 0, 48000, 2, 48000), 440, 1);
    XCTAssertFalse(findBeepOnset(pcm.data(), 48000, 2, 48000).has_value());
}

- (void)testComposedWriterRoutesEncodersIntoMuxer {
    Log log;
    ComposedMediaWriter writer(std::make_unique<FakeVideoEncoder>(log), std::make_unique<FakeAudioEncoder>(log),
                               std::make_unique<FakeMuxer>(log));
    EncodeSettings settings;
    VideoEncodeSettings v;
    v.width = 64;
    v.height = 32;
    settings.video = v;
    settings.audio = AudioEncodeSettings{};
    XCTAssertTrue(writer.open("/unused", settings).ok());
    XCTAssertTrue(writer.usesHardwareVideoEncoder());
    const std::vector<std::string> openOrder = {"mux.open", "video.open", "mux.addVideo", "audio.open",
                                                "mux.addAudio", "mux.begin"};
    XCTAssertTrue(log.events == openOrder);

    int frame = 0;
    std::vector<float> silence(ComposedMediaWriter::kPullAudioChunkFrames * 2);
    int64_t audioLeft = 48000; // 1 s of audio, 30 frames of video.
    Status s = writer.runPull(
        [&]() -> Result<std::optional<VideoInput>> {
            if (frame == 30) {
                return std::optional<VideoInput>();
            }
            auto image = writer.makePixelBuffer();
            if (!image.ok()) {
                return std::move(image).error();
            }
            return std::optional<VideoInput>(VideoInput{image.value(), CMTimeMake(frame++, 30)});
        },
        [&](float *dst, int maxFrames) -> Result<int> {
            const int n = static_cast<int>(std::min<int64_t>(maxFrames, audioLeft));
            std::copy_n(silence.data(), n * 2, dst);
            audioLeft -= n;
            return n;
        });
    XCTAssertTrue(s.ok());
    XCTAssertTrue(writer.finish().ok());
    XCTAssertEqual(log.events.back(), "mux.finish");

    int videoPackets = 0;
    int audioPackets = 0;
    double lastVideo = -1;
    double maxSkew = 0;
    double lastAudio = 0;
    for (const EncodedPacket &p : log.packets) {
        if (p.streamIndex == 0) {
            ++videoPackets;
            XCTAssertGreaterThan(CMTimeGetSeconds(p.pts), lastVideo);
            lastVideo = CMTimeGetSeconds(p.pts);
        } else {
            XCTAssertEqual(p.streamIndex, 1);
            ++audioPackets;
            lastAudio = CMTimeGetSeconds(p.pts);
        }
        if (videoPackets > 0 && audioPackets > 0) {
            maxSkew = std::max(maxSkew, std::fabs(lastVideo - lastAudio));
        }
    }
    XCTAssertEqual(videoPackets, 30, @"the delayed frame is flushed");
    XCTAssertEqual(audioPackets, 46); // floor(48000 / 1024)
    XCTAssertLessThan(maxSkew, 0.2, @"pull mode interleaves by media time");
    XCTAssertFalse(writer.appendVideo({}, kCMTimeZero).ok(), @"no appends after finish");
}

@end
