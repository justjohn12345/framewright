#include "AppleWriter.h"

#include "../CFRef.h"
#include "../ColorTags.h"
#include "AppleSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <os/log.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <vector>

/// Forwards KVO changes of an AVAssetWriterInput's readyForMoreMediaData to a block.
@interface VEWriterReadyObserver : NSObject
- (instancetype)initWithHandler:(void (^)(void))handler;
@end

@implementation VEWriterReadyObserver {
    void (^_handler)(void);
}
- (instancetype)initWithHandler:(void (^)(void))handler {
    if ((self = [super init])) {
        _handler = [handler copy];
    }
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    _handler();
}
@end

namespace ve::media::apple {

namespace {

os_log_t writerLog() {
    static os_log_t log = os_log_create("ve.media.apple", "writer");
    return log;
}

NSString *const kReadyKeyPath = @"readyForMoreMediaData";
constexpr int kPullAudioChunkFrames = 4096;

AVFileType fileType(ContainerFormat c) {
    switch (c) {
    case ContainerFormat::MOV:
        return AVFileTypeQuickTimeMovie;
    case ContainerFormat::MP4:
        return AVFileTypeMPEG4;
    case ContainerFormat::M4A:
        return AVFileTypeAppleM4A;
    case ContainerFormat::WAV:
        return AVFileTypeWAVE;
    case ContainerFormat::MKV:
        break; // Refused by validate(): AVAssetWriter has no Matroska muxer.
    }
    return AVFileTypeQuickTimeMovie;
}

/// `hardware`: require the hardware encoder (true) or forbid it (false). Never "either": the
/// writer then knows which encoder runs (AVAssetWriter does not expose its session).
NSDictionary *videoOutputSettings(const VideoEncodeSettings &v, bool hardware) {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    switch (v.codec) {
    case VideoCodec::H264:
        s[AVVideoCodecKey] = AVVideoCodecTypeH264;
        break;
    case VideoCodec::HEVC:
        s[AVVideoCodecKey] = AVVideoCodecTypeHEVC;
        break;
    case VideoCodec::ProRes422:
        s[AVVideoCodecKey] = AVVideoCodecTypeAppleProRes422;
        break;
    case VideoCodec::AV1:
        break; // Refused by validate(): VideoToolbox has no AV1 encoder.
    }
    s[AVVideoWidthKey] = @(v.width);
    s[AVVideoHeightKey] = @(v.height);
    CFStringRef primaries = cvString(v.color.primaries);
    CFStringRef transfer = cvString(v.color.transfer);
    CFStringRef matrix = cvString(v.color.matrix);
    if (primaries && transfer && matrix) { // AVFoundation requires all three together.
        s[AVVideoColorPropertiesKey] = @{
            AVVideoColorPrimariesKey : (__bridge NSString *)primaries,
            AVVideoTransferFunctionKey : (__bridge NSString *)transfer,
            AVVideoYCbCrMatrixKey : (__bridge NSString *)matrix,
        };
    }
    s[AVVideoEncoderSpecificationKey] = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @(hardware),
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @(hardware),
    };
    if (v.codec != VideoCodec::ProRes422) {
        NSMutableDictionary *c = [NSMutableDictionary dictionary];
        if (v.averageBitRate > 0) {
            c[AVVideoAverageBitRateKey] = @(v.averageBitRate);
        } else if (v.quality >= 0) {
            c[AVVideoQualityKey] = @(std::min(1.0, v.quality));
        }
        if (v.maxKeyFrameInterval > 0) {
            c[AVVideoMaxKeyFrameIntervalKey] = @(v.maxKeyFrameInterval);
        }
        const double fps = 1.0 / CMTimeGetSeconds(v.frameDuration);
        c[AVVideoExpectedSourceFrameRateKey] = @(std::lround(fps));
        c[AVVideoAllowFrameReorderingKey] = @(v.allowFrameReordering);
        // HEVC from 10-bit input ('x420') is Main10, else Main.
        c[AVVideoProfileLevelKey] = v.codec == VideoCodec::H264 ? AVVideoProfileLevelH264HighAutoLevel
                                    : isTenBitPixelFormat(v.inputPixelFormat)
                                        ? (__bridge NSString *)kVTProfileLevel_HEVC_Main10_AutoLevel
                                        : (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel;
        s[AVVideoCompressionPropertiesKey] = c;
    }
    return s;
}

NSDictionary *audioOutputSettings(const AudioEncodeSettings &a) {
    if (a.codec == AudioCodec::AAC) {
        return @{
            AVFormatIDKey : @(kAudioFormatMPEG4AAC),
            AVSampleRateKey : @(a.sampleRate),
            AVNumberOfChannelsKey : @(a.channels),
            AVEncoderBitRateKey : @(a.bitRate),
            AVChannelLayoutKey : channelLayoutData(a.channels),
        };
    }
    return @{
        AVFormatIDKey : @(kAudioFormatLinearPCM),
        AVSampleRateKey : @(a.sampleRate),
        AVNumberOfChannelsKey : @(a.channels),
        AVLinearPCMBitDepthKey : @(a.pcmBitDepth),
        AVLinearPCMIsFloatKey : @(a.pcmBitDepth == 32),
        AVLinearPCMIsBigEndianKey : @NO,
        AVLinearPCMIsNonInterleaved : @NO,
        AVChannelLayoutKey : channelLayoutData(a.channels),
    };
}

/// State shared with the requestMediaDataWhenReady blocks. Held by shared_ptr so a block that
/// AVFoundation invokes late never touches freed memory.
struct PullState {
    std::mutex mutex;
    std::optional<MediaError> error;
    std::atomic<bool> abort{false};
    std::atomic<bool> videoDone{false};
    std::atomic<bool> audioDone{false};
    dispatch_group_t group = dispatch_group_create();
    VideoPullFn video;
    AudioPullFn audio;

    void fail(MediaError e) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!error) {
            error = std::move(e);
        }
        abort = true;
    }
};

} // namespace

struct AppleWriter::Impl {
    enum class State { Idle, Writing, Finished, Failed };

    State state = State::Idle;
    EncodeSettings settings;
    std::string path;
    AVAssetWriter *writer = nil;
    AVAssetWriterInput *videoInput = nil;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
    AVAssetWriterInput *audioInput = nil;
    CFRef<CMAudioFormatDescriptionRef> audioFormat;
    PixelBufferPool fallbackPool;

    CMTime lastVideoPts = kCMTimeInvalid;
    int64_t audioFramesWritten = 0;
    bool videoMarkedFinished = false;
    bool audioMarkedFinished = false;
    bool pushed = false;
    bool pulled = false;

    /// Readiness wake-ups. The KVO handler (on an AVFoundation thread) only bumps the counter
    /// and notifies; waitUntilReady() never calls into AVFoundation while holding readyMutex,
    /// so the two cannot deadlock on AVFoundation's internal locks.
    std::mutex readyMutex;
    std::condition_variable readyChanged;
    std::atomic<uint64_t> readyGeneration{0};
    VEWriterReadyObserver *observer = nil;
    bool hardwareEncoder = false; ///< The video input runs on the hardware encoder (required at open).

    ~Impl() {
        removeObservers();
        if (state == State::Writing) {
            cancelAndDelete();
        }
    }

    void removeObservers() {
        if (observer == nil) {
            return;
        }
        for (AVAssetWriterInput *input in inputs()) {
            [input removeObserver:observer forKeyPath:kReadyKeyPath];
        }
        observer = nil;
    }

    NSArray<AVAssetWriterInput *> *inputs() const {
        NSMutableArray *a = [NSMutableArray array];
        if (videoInput) {
            [a addObject:videoInput];
        }
        if (audioInput) {
            [a addObject:audioInput];
        }
        return a;
    }

    void cancelAndDelete() {
        if (writer != nil && writer.status == AVAssetWriterStatusWriting) {
            [writer cancelWriting];
        }
        [NSFileManager.defaultManager removeItemAtPath:@(path.c_str()) error:nil];
        state = State::Failed;
    }

    MediaError writerError(MediaErrorCode code, const std::string &context) {
        if (writer.status == AVAssetWriterStatusFailed) {
            return errorFromNSError(writer.error, code, context);
        }
        return makeError(code, context + " failed (writer status " + std::to_string(writer.status) + ")");
    }

    Status waitUntilReady(AVAssetWriterInput *input) {
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::milliseconds(static_cast<int>(kStallTimeoutSeconds * 1000));
        while (true) {
            // Sample the generation before asking AVFoundation: a KVO change after the question
            // bumps it, so the wait below cannot miss it. AVFoundation is only called unlocked.
            const uint64_t seen = readyGeneration.load(std::memory_order_acquire);
            if (input.readyForMoreMediaData) {
                return okStatus();
            }
            if (writer.status != AVAssetWriterStatusWriting) {
                return writerError(MediaErrorCode::EncodeFailed, "AVAssetWriter");
            }
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                return makeError(MediaErrorCode::Timeout,
                                 "AVAssetWriter input not ready for 10 s (in push mode keep audio up to 2 s "
                                 "ahead of video and call endStream(), or use runPull())");
            }
            std::unique_lock<std::mutex> lock(readyMutex);
            // KVO wakes us promptly; the periodic timeout re-checks the writer status (a failure
            // does not always change readyForMoreMediaData).
            readyChanged.wait_until(lock, std::min(deadline, now + std::chrono::milliseconds(50)), [&] {
                return readyGeneration.load(std::memory_order_acquire) != seen;
            });
        }
    }

    Result<CFRef<CMSampleBufferRef>> makeAudioSample(const float *data, int frames) {
        const int ch = settings.audio->channels;
        const size_t bytes = static_cast<size_t>(frames) * static_cast<size_t>(ch) * sizeof(float);
        CFRef<CMBlockBufferRef> block;
        OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes, kCFAllocatorDefault,
                                                         nullptr, 0, bytes, kCMBlockBufferAssureMemoryNowFlag,
                                                         block.outPtr());
        if (st != kCMBlockBufferNoErr) {
            return errorFromOSStatus(st, MediaErrorCode::Internal, "CMBlockBufferCreateWithMemoryBlock");
        }
        st = CMBlockBufferReplaceDataBytes(data, block.get(), 0, bytes);
        if (st != kCMBlockBufferNoErr) {
            return errorFromOSStatus(st, MediaErrorCode::Internal, "CMBlockBufferReplaceDataBytes");
        }
        CFRef<CMSampleBufferRef> sample;
        const CMTime pts = CMTimeMake(audioFramesWritten, static_cast<int32_t>(settings.audio->sampleRate));
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block.get(), audioFormat.get(),
                                                                  frames, pts, nullptr, sample.outPtr());
        if (st != noErr) {
            return errorFromOSStatus(st, MediaErrorCode::Internal,
                                     "CMAudioSampleBufferCreateReadyWithPacketDescriptions");
        }
        return sample;
    }

    Status appendAudioSample(const float *data, int frames) {
        auto sample = makeAudioSample(data, frames);
        if (!sample.ok()) {
            return std::move(sample).error();
        }
        BOOL ok = NO;
        @try {
            ok = [audioInput appendSampleBuffer:sample->get()];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::EncodeFailed, "appendSampleBuffer: " + toStdString(e.reason));
        }
        if (!ok) {
            return writerError(MediaErrorCode::EncodeFailed, "audio appendSampleBuffer");
        }
        audioFramesWritten += frames;
        return okStatus();
    }

    Status appendVideoFrame(CVPixelBufferRef image, CMTime pts) {
        if (!CMTIME_IS_NUMERIC(pts) || (CMTIME_IS_NUMERIC(lastVideoPts) && CMTimeCompare(pts, lastVideoPts) <= 0)) {
            return makeError(MediaErrorCode::InvalidArgument, "video pts must be numeric and strictly increasing");
        }
        if (image == nullptr) {
            return makeError(MediaErrorCode::InvalidArgument, "null pixel buffer");
        }
        BOOL ok = NO;
        @try {
            ok = [adaptor appendPixelBuffer:image withPresentationTime:pts];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::EncodeFailed, "appendPixelBuffer: " + toStdString(e.reason));
        }
        if (!ok) {
            return writerError(MediaErrorCode::EncodeFailed, "appendPixelBuffer");
        }
        lastVideoPts = pts;
        return okStatus();
    }

    bool createdWithHardware = false;

    /// Creates the AVAssetWriter with its inputs and starts writing. `hardware` requires the
    /// hardware video encoder (true) or forbids it (false). On failure nothing is left behind
    /// (no writer, no inputs, no partial file).
    Status createWriter(bool hardware) {
        Status s = createWriterAttempt(hardware);
        if (!s.ok()) {
            if (writer != nil && writer.status == AVAssetWriterStatusWriting) {
                [writer cancelWriting];
            }
            writer = nil;
            videoInput = nil;
            adaptor = nil;
            audioInput = nil;
            audioFormat.reset();
            [NSFileManager.defaultManager removeItemAtPath:@(path.c_str()) error:nil];
        }
        createdWithHardware = s.ok() && hardware;
        return s;
    }

    Status createWriterAttempt(bool hardware) {
        NSError *error = nil;
        AVAssetWriter *w = [[AVAssetWriter alloc] initWithURL:fileURL(path)
                                                     fileType:fileType(settings.container)
                                                        error:&error];
        if (w == nil) {
            return errorFromNSError(error, MediaErrorCode::WriteFailed, "AVAssetWriter init");
        }
        w.shouldOptimizeForNetworkUse = settings.container == ContainerFormat::MP4;
        writer = w;
        @try {
            if (settings.video) {
                const VideoEncodeSettings &v = *settings.video;
                NSDictionary *out = videoOutputSettings(v, hardware);
                if (![w canApplyOutputSettings:out forMediaType:AVMediaTypeVideo]) {
                    return makeError(MediaErrorCode::UnsupportedCodec,
                                     std::string("AVAssetWriter cannot apply the ") + toString(v.codec) + " settings");
                }
                AVAssetWriterInput *input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                                           outputSettings:out];
                input.expectsMediaDataInRealTime = NO;
                int32_t timescale = v.frameDuration.timescale;
                while (timescale < 600) {
                    timescale *= 2;
                }
                input.mediaTimeScale = timescale;
                NSDictionary *sourceAttributes = CFBridgingRelease(createPixelBufferAttributes(
                    v.inputPixelFormat, static_cast<size_t>(v.width), static_cast<size_t>(v.height)));
                adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:input
                                                                     sourcePixelBufferAttributes:sourceAttributes];
                if (![w canAddInput:input]) {
                    return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter cannot add the video input");
                }
                [w addInput:input];
                videoInput = input;
            }
            if (settings.audio) {
                const AudioEncodeSettings &a = *settings.audio;
                NSDictionary *out = audioOutputSettings(a);
                if (![w canApplyOutputSettings:out forMediaType:AVMediaTypeAudio]) {
                    return makeError(MediaErrorCode::UnsupportedCodec,
                                     std::string("AVAssetWriter cannot apply the ") + toString(a.codec) + " settings");
                }
                AVAssetWriterInput *input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                                           outputSettings:out];
                input.expectsMediaDataInRealTime = NO;
                if (![w canAddInput:input]) {
                    return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter cannot add the audio input");
                }
                [w addInput:input];
                audioInput = input;

                AudioStreamBasicDescription asbd{};
                asbd.mSampleRate = a.sampleRate;
                asbd.mFormatID = kAudioFormatLinearPCM;
                asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                asbd.mBitsPerChannel = 32;
                asbd.mChannelsPerFrame = static_cast<UInt32>(a.channels);
                asbd.mFramesPerPacket = 1;
                asbd.mBytesPerFrame = 4 * static_cast<UInt32>(a.channels);
                asbd.mBytesPerPacket = asbd.mBytesPerFrame;
                NSData *layout = channelLayoutData(a.channels);
                const OSStatus st = CMAudioFormatDescriptionCreate(
                    kCFAllocatorDefault, &asbd, layout.length, static_cast<const AudioChannelLayout *>(layout.bytes),
                    0, nullptr, nullptr, audioFormat.outPtr());
                if (st != noErr) {
                    return errorFromOSStatus(st, MediaErrorCode::Internal, "CMAudioFormatDescriptionCreate");
                }
            }
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter rejected the settings: " +
                                                                   toStdString(e.reason));
        }
        if (![w startWriting]) {
            return errorFromNSError(w.error, MediaErrorCode::WriteFailed, "AVAssetWriter startWriting");
        }
        [w startSessionAtSourceTime:kCMTimeZero];
        return okStatus();
    }

    void markFinished(AVAssetWriterInput *input, bool &flag) {
        if (input != nil && !flag) {
            flag = true;
            @try {
                [input markAsFinished];
            } @catch (NSException *) {
                // Only throws when the writer already failed; finish() reports that error.
            }
        }
    }
};

AppleWriter::AppleWriter() : impl_(std::make_unique<Impl>()) {}

AppleWriter::~AppleWriter() = default;

Status AppleWriter::validate(const EncodeSettings &s) {
    if (!s.video && !s.audio) {
        return makeError(MediaErrorCode::InvalidArgument, "no video or audio stream configured");
    }
    if (s.video) {
        const VideoEncodeSettings &v = *s.video;
        if (v.width <= 0 || v.height <= 0 || v.width > 16384 || v.height > 16384 || (v.width | v.height) & 1) {
            return makeError(MediaErrorCode::InvalidArgument, "video size must be positive, even and <= 16384");
        }
        if (!CMTIME_IS_NUMERIC(v.frameDuration) || CMTimeCompare(v.frameDuration, kCMTimeZero) <= 0) {
            return makeError(MediaErrorCode::InvalidArgument, "frame duration must be positive");
        }
        if (s.container == ContainerFormat::WAV || s.container == ContainerFormat::M4A) {
            return makeError(MediaErrorCode::InvalidArgument, "container cannot hold video");
        }
        if (s.container == ContainerFormat::MP4 && v.codec == VideoCodec::ProRes422) {
            return makeError(MediaErrorCode::UnsupportedCodec, "ProRes requires a QuickTime (.mov) container");
        }
        if (v.codec == VideoCodec::AV1) {
            return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter cannot encode AV1");
        }
        if (isTenBitPixelFormat(v.inputPixelFormat) && v.codec == VideoCodec::H264) {
            return makeError(MediaErrorCode::UnsupportedFormat, "H.264 is encoded from 8-bit input only");
        }
    }
    if (s.container == ContainerFormat::MKV) {
        return makeError(MediaErrorCode::UnsupportedFormat, "AVAssetWriter cannot write Matroska");
    }
    if (s.audio) {
        const AudioEncodeSettings &a = *s.audio;
        if (a.channels < 1 || a.channels > 8 || !(a.sampleRate >= 8000 && a.sampleRate <= 192000) ||
            std::floor(a.sampleRate) != a.sampleRate) {
            return makeError(MediaErrorCode::InvalidArgument, "audio needs 1...8 channels and an integral rate");
        }
        if (a.codec == AudioCodec::LinearPCM && a.pcmBitDepth != 16 && a.pcmBitDepth != 24 && a.pcmBitDepth != 32) {
            return makeError(MediaErrorCode::InvalidArgument, "PCM bit depth must be 16, 24 or 32");
        }
        if (s.container == ContainerFormat::WAV && a.codec != AudioCodec::LinearPCM) {
            return makeError(MediaErrorCode::UnsupportedCodec, "WAV holds linear PCM only");
        }
        if ((s.container == ContainerFormat::M4A || s.container == ContainerFormat::MP4) &&
            a.codec == AudioCodec::LinearPCM) {
            return makeError(MediaErrorCode::UnsupportedCodec, "linear PCM requires .mov or .wav");
        }
    }
    return okStatus();
}

Status AppleWriter::open(const std::string &path, const EncodeSettings &settings) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Idle) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    VE_MEDIA_TRY(validate(settings));
    @autoreleasepool {
        d.settings = settings;
        d.path = path;
        NSString *p = @(path.c_str());
        if (p == nil || path.empty()) {
            return makeError(MediaErrorCode::InvalidArgument, "invalid output path");
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:p]) {
            NSError *removeError = nil;
            if (![fm removeItemAtPath:p error:&removeError]) {
                return errorFromNSError(removeError, MediaErrorCode::PermissionDenied, "removing existing output");
            }
        }
        // Video: the hardware encoder first (required, so AVAssetWriter fails at startWriting
        // when VideoToolbox has none for these settings, e.g. H.264 above 4096x2304), then, unless
        // the caller required hardware, the software encoder explicitly. Either way the writer
        // knows which encoder runs.
        Status s = d.createWriter(true);
        if (!s.ok() && settings.video && !settings.video->requireHardware) {
            const MediaError hardwareError = s.error();
            s = d.createWriter(false);
            if (s.ok()) {
                os_log_info(writerLog(), "%{public}s: no hardware %{public}s encoder for %dx%d (%{public}s); "
                                         "encoding in software",
                            path.c_str(), toString(settings.video->codec), settings.video->width,
                            settings.video->height, hardwareError.description().c_str());
            }
        }
        if (!s.ok()) {
            return s;
        }
        d.hardwareEncoder = settings.video.has_value() && d.createdWithHardware;
        d.state = Impl::State::Writing;

        Impl *impl = &d;
        d.observer = [[VEWriterReadyObserver alloc] initWithHandler:^{
            impl->readyGeneration.fetch_add(1, std::memory_order_acq_rel);
            std::lock_guard<std::mutex> lock(impl->readyMutex);
            impl->readyChanged.notify_all();
        }];
        for (AVAssetWriterInput *input in d.inputs()) {
            [input addObserver:d.observer
                    forKeyPath:kReadyKeyPath
                       options:NSKeyValueObservingOptionNew
                       context:nullptr];
        }
        return okStatus();
    }
}

Result<PixelBuffer> AppleWriter::makePixelBuffer() {
    Impl &d = *impl_;
    if (d.state != Impl::State::Writing || d.adaptor == nil) {
        return makeError(MediaErrorCode::InvalidState, "makePixelBuffer() needs an open writer with video");
    }
    CVPixelBufferPoolRef pool = d.adaptor.pixelBufferPool;
    if (pool != nullptr) {
        CVPixelBufferRef buffer = nullptr;
        const CVReturn rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
        if (rc == kCVReturnSuccess && buffer != nullptr) {
            return PixelBuffer::adopt(buffer);
        }
    }
    // The adaptor's pool is unavailable after a writer failure; a private pool keeps the
    // caller going until append reports the failure.
    if (!d.fallbackPool) {
        const VideoEncodeSettings &v = *d.settings.video;
        auto created = PixelBufferPool::create(v.inputPixelFormat, static_cast<size_t>(v.width),
                                               static_cast<size_t>(v.height));
        if (!created.ok()) {
            return std::move(created).error();
        }
        d.fallbackPool = std::move(created).value();
    }
    return d.fallbackPool.makeBuffer();
}

Status AppleWriter::appendVideo(const PixelBuffer &image, CMTime pts) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Writing || d.videoInput == nil || d.pulled || d.videoMarkedFinished) {
        return makeError(MediaErrorCode::InvalidState, "appendVideo() needs an open writer with video in push mode");
    }
    @autoreleasepool {
        d.pushed = true;
        VE_MEDIA_TRY(d.waitUntilReady(d.videoInput));
        return d.appendVideoFrame(image.get(), pts);
    }
}

Status AppleWriter::appendAudio(const float *interleaved, int frames) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Writing || d.audioInput == nil || d.pulled || d.audioMarkedFinished) {
        return makeError(MediaErrorCode::InvalidState, "appendAudio() needs an open writer with audio in push mode");
    }
    if (frames < 0 || (frames > 0 && interleaved == nullptr)) {
        return makeError(MediaErrorCode::InvalidArgument, "appendAudio() needs data");
    }
    if (frames == 0) {
        return okStatus();
    }
    @autoreleasepool {
        d.pushed = true;
        VE_MEDIA_TRY(d.waitUntilReady(d.audioInput));
        return d.appendAudioSample(interleaved, frames);
    }
}

Status AppleWriter::endStream(TrackKind kind) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Writing || d.pulled) {
        return makeError(MediaErrorCode::InvalidState, "endStream() needs an open writer in push mode");
    }
    if (kind == TrackKind::Video && d.videoInput != nil) {
        d.markFinished(d.videoInput, d.videoMarkedFinished);
        return okStatus();
    }
    if (kind == TrackKind::Audio && d.audioInput != nil) {
        d.markFinished(d.audioInput, d.audioMarkedFinished);
        return okStatus();
    }
    return makeError(MediaErrorCode::InvalidArgument, "endStream() for a stream that is not configured");
}

Status AppleWriter::runPull(const VideoPullFn &video, const AudioPullFn &audio) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Writing || d.pushed || d.pulled) {
        return makeError(MediaErrorCode::InvalidState, "runPull() needs an open writer that has not been fed");
    }
    if ((d.videoInput != nil && !video) || (d.audioInput != nil && !audio)) {
        return makeError(MediaErrorCode::InvalidArgument, "runPull() needs a callback for every configured stream");
    }
    d.pulled = true;
    auto state = std::make_shared<PullState>();
    state->video = video;
    state->audio = audio;
    Impl *impl = &d;

    dispatch_queue_t videoQueue = nil;
    dispatch_queue_t audioQueue = nil;
    if (d.videoInput != nil) {
        videoQueue = dispatch_queue_create("framewright.writer.video", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(state->group);
        AVAssetWriterInput *input = d.videoInput;
        [input requestMediaDataWhenReadyOnQueue:videoQueue
                                     usingBlock:^{
                                         if (state->videoDone) {
                                             return;
                                         }
                                         while (input.readyForMoreMediaData) {
                                             @autoreleasepool {
                                                 Status s = okStatus();
                                                 bool done = state->abort;
                                                 if (!done) {
                                                     auto next = state->video();
                                                     if (!next.ok()) {
                                                         s = std::move(next).error();
                                                     } else if (!next.value()) {
                                                         done = true;
                                                     } else {
                                                         s = impl->appendVideoFrame(next.value()->image.get(),
                                                                                    next.value()->pts);
                                                     }
                                                 }
                                                 if (!s.ok()) {
                                                     state->fail(std::move(s).error());
                                                     done = true;
                                                 }
                                                 if (done) {
                                                     impl->markFinished(input, impl->videoMarkedFinished);
                                                     if (!state->videoDone.exchange(true)) {
                                                         dispatch_group_leave(state->group);
                                                     }
                                                     return;
                                                 }
                                             }
                                         }
                                     }];
    }
    if (d.audioInput != nil) {
        audioQueue = dispatch_queue_create("framewright.writer.audio", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(state->group);
        AVAssetWriterInput *input = d.audioInput;
        const int channels = d.settings.audio->channels;
        auto buffer = std::make_shared<std::vector<float>>(static_cast<size_t>(kPullAudioChunkFrames * channels));
        [input requestMediaDataWhenReadyOnQueue:audioQueue
                                     usingBlock:^{
                                         if (state->audioDone) {
                                             return;
                                         }
                                         while (input.readyForMoreMediaData) {
                                             @autoreleasepool {
                                                 Status s = okStatus();
                                                 bool done = state->abort;
                                                 if (!done) {
                                                     auto n = state->audio(buffer->data(), kPullAudioChunkFrames);
                                                     if (!n.ok()) {
                                                         s = std::move(n).error();
                                                     } else if (n.value() <= 0) {
                                                         done = true;
                                                     } else if (n.value() > kPullAudioChunkFrames) {
                                                         s = makeError(MediaErrorCode::InvalidArgument,
                                                                       "audio pull returned more than maxFrames");
                                                     } else {
                                                         s = impl->appendAudioSample(buffer->data(), n.value());
                                                     }
                                                 }
                                                 if (!s.ok()) {
                                                     state->fail(std::move(s).error());
                                                     done = true;
                                                 }
                                                 if (done) {
                                                     impl->markFinished(input, impl->audioMarkedFinished);
                                                     if (!state->audioDone.exchange(true)) {
                                                         dispatch_group_leave(state->group);
                                                     }
                                                     return;
                                                 }
                                             }
                                         }
                                     }];
    }

    // Wait for both streams. If the writer fails, AVFoundation stops invoking the blocks, so
    // watch the status and release the streams ourselves (after draining in-flight blocks).
    while (dispatch_group_wait(state->group, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
        if (d.writer.status == AVAssetWriterStatusFailed || d.writer.status == AVAssetWriterStatusCancelled) {
            state->fail(d.writerError(MediaErrorCode::EncodeFailed, "AVAssetWriter"));
            // Serial queues: an empty synchronous block waits out any block still running.
            for (dispatch_queue_t queue : {videoQueue, audioQueue}) {
                if (queue) {
                    dispatch_sync(queue, ^{
                    });
                }
            }
            if (d.videoInput != nil && !state->videoDone.exchange(true)) {
                dispatch_group_leave(state->group);
            }
            if (d.audioInput != nil && !state->audioDone.exchange(true)) {
                dispatch_group_leave(state->group);
            }
        }
    }
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->error) {
        d.removeObservers();
        d.cancelAndDelete();
        return *state->error;
    }
    return okStatus();
}

Status AppleWriter::finish() {
    Impl &d = *impl_;
    if (d.state != Impl::State::Writing) {
        return makeError(MediaErrorCode::InvalidState, "finish() needs an open writer");
    }
    @autoreleasepool {
        d.markFinished(d.videoInput, d.videoMarkedFinished);
        d.markFinished(d.audioInput, d.audioMarkedFinished);
        // The session ends where the longer stream ends: one frame duration after the last video
        // frame (which makes that frame last exactly one frame) or at the end of the audio,
        // whichever is later, so audio that runs past the video is kept (the video track still
        // ends after its last frame).
        CMTime end = kCMTimeInvalid;
        if (d.videoInput != nil && CMTIME_IS_NUMERIC(d.lastVideoPts)) {
            end = CMTimeAdd(d.lastVideoPts, d.settings.video->frameDuration);
        }
        if (d.audioInput != nil && d.audioFramesWritten > 0) {
            const CMTime audioEnd = CMTimeMake(d.audioFramesWritten, static_cast<int32_t>(d.settings.audio->sampleRate));
            end = CMTIME_IS_NUMERIC(end) ? CMTimeMaximum(end, audioEnd) : audioEnd;
        }
        if (CMTIME_IS_NUMERIC(end)) {
            [d.writer endSessionAtSourceTime:end];
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [d.writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(done);
        }];
        const dispatch_time_t deadline =
            dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kFinishTimeoutSeconds * NSEC_PER_SEC));
        const bool timedOut = dispatch_semaphore_wait(done, deadline) != 0;
        d.removeObservers();
        if (timedOut) {
            d.cancelAndDelete();
            return makeError(MediaErrorCode::Timeout, "AVAssetWriter finishWriting timed out");
        }
        if (d.writer.status != AVAssetWriterStatusCompleted) {
            MediaError e = d.writerError(MediaErrorCode::WriteFailed, "AVAssetWriter finishWriting");
            d.cancelAndDelete();
            return e;
        }
        d.state = Impl::State::Finished;
        return okStatus();
    }
}

void AppleWriter::cancel() {
    Impl &d = *impl_;
    @autoreleasepool {
        d.removeObservers();
        if (d.state == Impl::State::Writing) {
            d.cancelAndDelete();
        }
    }
}

bool AppleWriter::usesHardwareVideoEncoder() const {
    return impl_->hardwareEncoder;
}

std::string AppleWriter::videoEncoderName() const {
    const Impl &d = *impl_;
    if (d.state == Impl::State::Idle || !d.settings.video) {
        return {};
    }
    const char *codec = "H.264";
    switch (d.settings.video->codec) {
    case VideoCodec::H264:
        break;
    case VideoCodec::HEVC:
        codec = isTenBitPixelFormat(d.settings.video->inputPixelFormat) ? "HEVC Main10" : "HEVC";
        break;
    case VideoCodec::ProRes422:
        codec = "ProRes 422";
        break;
    case VideoCodec::AV1:
        codec = "AV1";
        break;
    }
    return std::string("VideoToolbox ") + codec + (d.hardwareEncoder ? " (hardware)" : " (software)");
}

} // namespace ve::media::apple
