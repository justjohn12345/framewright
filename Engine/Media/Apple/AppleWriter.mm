#include "AppleWriter.h"

#include "../CFRef.h"
#include "../ColorTags.h"
#include "../HardwareCaps.h"
#include "AppleSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

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
    }
    return AVFileTypeQuickTimeMovie;
}

NSDictionary *videoOutputSettings(const VideoEncodeSettings &v) {
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
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES,
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder :
            @(v.requireHardware),
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
        c[AVVideoProfileLevelKey] = v.codec == VideoCodec::H264
                                        ? AVVideoProfileLevelH264HighAutoLevel
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

    std::mutex readyMutex;
    std::condition_variable readyChanged;
    VEWriterReadyObserver *observer = nil;

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
        std::unique_lock<std::mutex> lock(readyMutex);
        while (!input.readyForMoreMediaData) {
            if (writer.status != AVAssetWriterStatusWriting) {
                return writerError(MediaErrorCode::EncodeFailed, "AVAssetWriter");
            }
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                return makeError(MediaErrorCode::Timeout,
                                 "AVAssetWriter input not ready for 10 s (in push mode keep audio up to 2 s "
                                 "ahead of video and call endStream(), or use runPull())");
            }
            // KVO wakes us promptly; the short timeout covers a change between check and wait.
            readyChanged.wait_until(lock, std::min(deadline, now + std::chrono::milliseconds(20)));
        }
        return okStatus();
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
        NSError *error = nil;
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:fileURL(path)
                                                          fileType:fileType(settings.container)
                                                             error:&error];
        if (writer == nil) {
            return errorFromNSError(error, MediaErrorCode::WriteFailed, "AVAssetWriter init");
        }
        writer.shouldOptimizeForNetworkUse = settings.container == ContainerFormat::MP4;
        d.writer = writer;

        @try {
            if (settings.video) {
                const VideoEncodeSettings &v = *settings.video;
                NSDictionary *out = videoOutputSettings(v);
                if (![writer canApplyOutputSettings:out forMediaType:AVMediaTypeVideo]) {
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
                d.adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:input
                                                                       sourcePixelBufferAttributes:sourceAttributes];
                if (![writer canAddInput:input]) {
                    return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter cannot add the video input");
                }
                [writer addInput:input];
                d.videoInput = input;
            }
            if (settings.audio) {
                const AudioEncodeSettings &a = *settings.audio;
                NSDictionary *out = audioOutputSettings(a);
                if (![writer canApplyOutputSettings:out forMediaType:AVMediaTypeAudio]) {
                    return makeError(MediaErrorCode::UnsupportedCodec,
                                     std::string("AVAssetWriter cannot apply the ") + toString(a.codec) + " settings");
                }
                AVAssetWriterInput *input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                                           outputSettings:out];
                input.expectsMediaDataInRealTime = NO;
                if (![writer canAddInput:input]) {
                    return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter cannot add the audio input");
                }
                [writer addInput:input];
                d.audioInput = input;

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
                    0, nullptr, nullptr, d.audioFormat.outPtr());
                if (st != noErr) {
                    return errorFromOSStatus(st, MediaErrorCode::Internal, "CMAudioFormatDescriptionCreate");
                }
            }
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetWriter rejected the settings: " +
                                                                   toStdString(e.reason));
        }

        if (![writer startWriting]) {
            return errorFromNSError(writer.error, MediaErrorCode::WriteFailed, "AVAssetWriter startWriting");
        }
        [writer startSessionAtSourceTime:kCMTimeZero];
        d.state = Impl::State::Writing;

        Impl *impl = &d;
        d.observer = [[VEWriterReadyObserver alloc] initWithHandler:^{
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
        videoQueue = dispatch_queue_create("videdit.writer.video", DISPATCH_QUEUE_SERIAL);
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
        audioQueue = dispatch_queue_create("videdit.writer.audio", DISPATCH_QUEUE_SERIAL);
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
        if (d.videoInput != nil && CMTIME_IS_NUMERIC(d.lastVideoPts)) {
            // Makes the last frame last exactly one frame duration.
            [d.writer endSessionAtSourceTime:CMTimeAdd(d.lastVideoPts, d.settings.video->frameDuration)];
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
    const Impl &d = *impl_;
    if (!d.settings.video) {
        return false;
    }
    return d.settings.video->requireHardware || HardwareCaps::get().hardwareEncode(codecType(d.settings.video->codec));
}

} // namespace ve::media::apple
