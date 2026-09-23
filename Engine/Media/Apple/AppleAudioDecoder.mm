#include "AppleAudioDecoder.h"

#include "../CFRef.h"
#include "AppleSupport.h"

#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <numeric>
#include <vector>

namespace ve::media::apple {

namespace {

/// Largest gap between buffers that is filled with zeros. A larger jump (a real discontinuity
/// or a damaged timestamp) is read as silence without materialising it: the data after the gap
/// waits until everything before it has been read.
constexpr double kMaxSilenceFillSeconds = 1.0;

int64_t floorDiv(int64_t a, int64_t b) {
    const int64_t q = a / b;
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

} // namespace

struct AppleAudioDecoder::Impl {
    double timeout;
    bool opened = false;
    double rate = 48000;
    int32_t timescale = 48000; ///< Integral output rate, used as CMTime timescale for positions.
    int channels = 2;
    int64_t length = 0;

    AVURLAsset *asset = nil;
    AVAssetTrack *track = nil;
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    bool readerDone = false;
    bool formatChecked = false;

    // Resampling (source rate != output rate): the reader decodes at the source rate and an
    // AVAudioConverter converts. AVAssetReader's own sample-rate conversion is not
    // sample-aligned (44.1 -> 48 kHz output lands 2 samples late and loses 17 at the end);
    // AVAudioConverter with priming is exact when fed from a source index whose output index is
    // an integer.
    int32_t sourceRate = 0; ///< Integral source rate; 0 = unknown (the reader converts).
    bool resampling = false;
    int64_t sourceStep = 1; ///< Source samples per aligned block (sourceRate / gcd).
    int64_t outputStep = 1; ///< Output samples per aligned block (rate / gcd).
    AVAudioFormat *sourceFormat = nil;
    AVAudioFormat *outFormat = nil;
    AVAudioConverter *converter = nil;
    bool converterStarted = false;
    int64_t sourceNext = 0; ///< Next source sample index the converter expects.
    int64_t outNext = 0;    ///< Output index of the converter's next output sample.

    int64_t position = 0;          ///< Next sample frame read() returns.
    std::vector<float> staged;     ///< Decoded frames starting at stagedStart.
    int64_t stagedStart = 0;
    int64_t streamContinuation = -1; ///< Expected start of the next buffer, -1 if unknown.
    /// Samples that follow a gap larger than kMaxSilenceFillSeconds, and where they start (in
    /// output samples; in source samples when resampling).
    std::vector<float> afterGap;
    int64_t afterGapStart = 0;
    bool haveAfterGap = false;

    explicit Impl(double t) : timeout(t) {}
    ~Impl() { stopReader(); }

    int64_t stagedFrames() const { return static_cast<int64_t>(staged.size()) / channels; }

    int64_t timeToSample(CMTime t, int32_t scale, CMTimeRoundingMethod rounding) const {
        return CMTimeConvertScale(t, scale, rounding).value;
    }

    void stopReader() {
        if (reader != nil && reader.status == AVAssetReaderStatusReading) {
            [reader cancelReading];
        }
        reader = nil;
        output = nil;
    }

    NSDictionary *outputSettings() const {
        return @{
            AVFormatIDKey : @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey : @32,
            AVLinearPCMIsFloatKey : @YES,
            AVLinearPCMIsBigEndianKey : @NO,
            AVLinearPCMIsNonInterleaved : @NO,
            AVSampleRateKey : @(resampling ? static_cast<double>(sourceRate) : rate),
            AVNumberOfChannelsKey : @(channels),
            AVChannelLayoutKey : decodedChannelLayoutData(channels),
        };
    }

    Status setUpResampling() {
        const int64_t g = std::gcd(static_cast<int64_t>(sourceRate), static_cast<int64_t>(timescale));
        sourceStep = sourceRate / g;
        outputStep = timescale / g;
        NSData *layoutData = decodedChannelLayoutData(channels);
        AVAudioChannelLayout *layout =
            [[AVAudioChannelLayout alloc] initWithLayout:static_cast<const AudioChannelLayout *>(layoutData.bytes)];
        sourceFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                        sampleRate:sourceRate
                                                       interleaved:YES
                                                     channelLayout:layout];
        outFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                     sampleRate:rate
                                                    interleaved:YES
                                                  channelLayout:layout];
        if (sourceFormat == nil || outFormat == nil) {
            return makeError(MediaErrorCode::Internal, "AVAudioFormat for resampling could not be created");
        }
        converter = [[AVAudioConverter alloc] initFromFormat:sourceFormat toFormat:outFormat];
        if (converter == nil) {
            return makeError(MediaErrorCode::UnsupportedFormat, "AVAudioConverter " + std::to_string(sourceRate) +
                                                                    " -> " + std::to_string(timescale) + " Hz");
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering;
        converter.sampleRateConverterQuality = AVAudioQualityMax;
        // Priming "normal": the converter behaves as if silence preceded the first input, so
        // output sample 0 corresponds to input sample 0 (verified: the 44.1 -> 48 kHz beep test
        // lands on the ideal sample and the length is exact).
        converter.primeMethod = AVAudioConverterPrimeMethod_Normal;
        return okStatus();
    }

    Status startReader(int64_t atSample) {
        stopReader();
        staged.clear();
        stagedStart = 0;
        streamContinuation = -1;
        afterGap.clear();
        haveAfterGap = false;
        converterStarted = false;
        readerDone = false;
        CMTime startTime = kCMTimeZero;
        if (resampling) {
            // Start at an aligned source index kPrerollSeconds before the target.
            const int64_t sourceTarget = floorDiv(atSample * sourceStep, outputStep);
            int64_t start = std::max<int64_t>(0, sourceTarget - static_cast<int64_t>(kPrerollSeconds * sourceRate));
            start = floorDiv(start, sourceStep) * sourceStep;
            startTime = CMTimeMake(start, sourceRate);
        } else {
            const int64_t start = std::max<int64_t>(0, atSample - static_cast<int64_t>(kPrerollSeconds * rate));
            startTime = CMTimeMake(start, timescale);
        }
        NSError *error = nil;
        AVAssetReader *r = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (r == nil) {
            return errorFromNSError(error, MediaErrorCode::DecodeFailed, "AVAssetReader init");
        }
        AVAssetReaderTrackOutput *o = nil;
        @try {
            o = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:outputSettings()];
            o.alwaysCopiesSampleData = NO;
            if (![r canAddOutput:o]) {
                return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetReader cannot add the audio track output");
            }
            [r addOutput:o];
            if (CMTimeCompare(startTime, kCMTimeZero) > 0) {
                r.timeRange = CMTimeRangeMake(startTime, kCMTimePositiveInfinity);
            }
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::UnsupportedCodec,
                             "AVAssetReaderTrackOutput rejected the audio settings: " + toStdString(e.reason));
        }
        if (![r startReading]) {
            return errorFromNSError(r.error, MediaErrorCode::DecodeFailed, "AVAssetReader startReading");
        }
        reader = r;
        output = o;
        return okStatus();
    }

    Status checkFormat(CMSampleBufferRef sample) {
        if (formatChecked) {
            return okStatus();
        }
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        const double expectedRate = resampling ? static_cast<double>(sourceRate) : rate;
        if (asbd == nullptr || asbd->mFormatID != kAudioFormatLinearPCM ||
            !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) ||
            (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) || asbd->mBitsPerChannel != 32 ||
            static_cast<int>(asbd->mChannelsPerFrame) != channels || std::fabs(asbd->mSampleRate - expectedRate) > 0.5) {
            return makeError(MediaErrorCode::Internal, "AVAssetReader delivered an unexpected PCM format");
        }
        formatChecked = true;
        return okStatus();
    }

    /// Drops staged samples before the read position.
    void trimConsumed() {
        const int64_t consumed = std::clamp<int64_t>(position - stagedStart, 0, stagedFrames());
        if (consumed > 0) {
            staged.erase(staged.begin(), staged.begin() + consumed * channels);
            stagedStart += consumed;
        }
    }

    // MARK: Converter

    /// Appends converter output at outNext.
    void appendConverted(const float *samples, int64_t frames) {
        if (frames <= 0) {
            return;
        }
        trimConsumed();
        if (staged.empty()) {
            stagedStart = outNext;
        }
        staged.insert(staged.end(), samples, samples + frames * channels);
        outNext += frames;
    }

    /// Feeds `frames` source samples (nullptr = zeros) and collects the output; with
    /// `endOfStream` flushes the converter afterwards (it must be restarted before more input).
    Status convert(const float *input, int64_t frames, bool endOfStream) {
        AVAudioPCMBuffer *in = nil;
        if (frames > 0) {
            in = [[AVAudioPCMBuffer alloc] initWithPCMFormat:sourceFormat frameCapacity:static_cast<AVAudioFrameCount>(frames)];
            if (in == nil) {
                return makeError(MediaErrorCode::Internal, "AVAudioPCMBuffer allocation failed");
            }
            in.frameLength = static_cast<AVAudioFrameCount>(frames);
            float *dst = in.floatChannelData[0];
            if (input != nullptr) {
                std::memcpy(dst, input, static_cast<size_t>(frames * channels) * sizeof(float));
            } else {
                std::fill_n(dst, frames * channels, 0.0f);
            }
        }
        __block AVAudioPCMBuffer *pending = in;
        const bool flush = endOfStream;
        const auto capacity =
            static_cast<AVAudioFrameCount>(frames * outputStep / sourceStep + 4096);
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFormat frameCapacity:capacity];
        if (out == nil) {
            return makeError(MediaErrorCode::Internal, "AVAudioPCMBuffer allocation failed");
        }
        while (true) {
            out.frameLength = 0;
            NSError *error = nil;
            const AVAudioConverterOutputStatus status =
                [converter convertToBuffer:out
                                     error:&error
                        withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount, AVAudioConverterInputStatus *outStatus) {
                            if (pending != nil) {
                                AVAudioPCMBuffer *give = pending;
                                pending = nil;
                                *outStatus = AVAudioConverterInputStatus_HaveData;
                                return give;
                            }
                            *outStatus = flush ? AVAudioConverterInputStatus_EndOfStream
                                               : AVAudioConverterInputStatus_NoDataNow;
                            return nil;
                        }];
            if (status == AVAudioConverterOutputStatus_Error) {
                return errorFromNSError(error, MediaErrorCode::DecodeFailed, "AVAudioConverter");
            }
            appendConverted(out.floatChannelData[0], out.frameLength);
            if (status == AVAudioConverterOutputStatus_EndOfStream) {
                converterStarted = false; // Needs a reset before new input.
                return okStatus();
            }
            if (status == AVAudioConverterOutputStatus_InputRanDry && pending == nil && out.frameLength == 0) {
                return okStatus();
            }
            if (status == AVAudioConverterOutputStatus_InputRanDry && pending == nil) {
                continue; // Collect what remains buffered for this input.
            }
        }
    }

    /// Places source samples starting at source index `start` (resampling path).
    Status placeSource(const float *data, int64_t count, int64_t start) {
        if (!converterStarted) {
            // (Re)start at the first source index whose output index is an integer.
            const int64_t aligned = floorDiv(start + sourceStep - 1, sourceStep) * sourceStep;
            const int64_t skip = aligned - start;
            if (skip >= count) {
                return okStatus();
            }
            data += skip * channels;
            count -= skip;
            start = aligned;
            [converter reset];
            converterStarted = true;
            sourceNext = start;
            outNext = start / sourceStep * outputStep;
            trimConsumed();
            if (!staged.empty() && stagedStart + stagedFrames() != outNext) {
                // Unread data before a restart that does not continue it: keep it, pad or cut.
                const int64_t gap = outNext - (stagedStart + stagedFrames());
                if (gap > 0) {
                    staged.insert(staged.end(), static_cast<size_t>(gap * channels), 0.0f);
                } else {
                    staged.resize(static_cast<size_t>(std::max<int64_t>(0, stagedFrames() + gap) * channels));
                }
            }
        } else {
            const int64_t diff = start - sourceNext;
            if (std::llabs(diff) > 1) {
                if (diff > 0 && static_cast<double>(diff) > kMaxSilenceFillSeconds * sourceRate) {
                    // Too far to fill: flush what the converter holds, keep this buffer for when
                    // the data before the gap has been read, then restart there.
                    VE_MEDIA_TRY(convert(nullptr, 0, true));
                    afterGap.assign(data, data + count * channels);
                    afterGapStart = start;
                    haveAfterGap = true;
                    return okStatus();
                }
                if (diff > 0) {
                    VE_MEDIA_TRY(convert(nullptr, diff, false)); // Fill the gap with silence.
                    sourceNext += diff;
                } else {
                    const int64_t overlap = -diff; // Keep the earlier data.
                    if (overlap >= count) {
                        return okStatus();
                    }
                    data += overlap * channels;
                    count -= overlap;
                }
            }
        }
        VE_MEDIA_TRY(convert(data, count, false));
        sourceNext += count;
        return okStatus();
    }

    // MARK: Reader

    /// Places output-rate samples starting at output index `start` (no resampling).
    Status placeOutput(const float *data, int64_t count, int64_t start) {
        if (streamContinuation >= 0 && std::llabs(start - streamContinuation) <= 1) {
            start = streamContinuation; // Timestamp rounding jitter, not a real gap.
        }
        trimConsumed();
        if (staged.empty()) {
            stagedStart = start;
        } else if (start != stagedStart + stagedFrames()) {
            const int64_t gap = start - (stagedStart + stagedFrames());
            if (gap > 0 && static_cast<double>(gap) > kMaxSilenceFillSeconds * rate) {
                afterGap.assign(data, data + count * channels);
                afterGapStart = start;
                haveAfterGap = true;
                streamContinuation = start + count;
                return okStatus();
            }
            if (gap > 0) {
                staged.insert(staged.end(), static_cast<size_t>(gap * channels), 0.0f);
            } else {
                // Overlap: keep the earlier data, drop the overlapping part of the new buffer.
                const int64_t skip = std::min<int64_t>(-gap, count);
                staged.insert(staged.end(), data + skip * channels, data + count * channels);
                streamContinuation = start + count;
                return okStatus();
            }
        }
        staged.insert(staged.end(), data, data + count * channels);
        streamContinuation = start + count;
        return okStatus();
    }

    /// Reads the next decoded buffer from the reader and places it.
    Status fetch() {
        CMSampleBufferRef raw = nullptr;
        @try {
            raw = [output copyNextSampleBuffer];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::DecodeFailed, "copyNextSampleBuffer: " + toStdString(e.reason));
        }
        if (raw == nullptr) {
            if (reader.status == AVAssetReaderStatusFailed) {
                return errorFromNSError(reader.error, MediaErrorCode::DecodeFailed, "AVAssetReader");
            }
            if (resampling && converterStarted) {
                VE_MEDIA_TRY(convert(nullptr, 0, true)); // The converter's tail.
            }
            readerDone = true;
            return okStatus();
        }
        CFRef<CMSampleBufferRef> sample = CFRef<CMSampleBufferRef>::adopt(raw);
        const CMItemCount count = CMSampleBufferGetNumSamples(sample.get());
        if (count <= 0) {
            return okStatus();
        }
        VE_MEDIA_TRY(checkFormat(sample.get()));
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample.get());
        const size_t bytes = static_cast<size_t>(count) * static_cast<size_t>(channels) * sizeof(float);
        if (block == nullptr || CMBlockBufferGetDataLength(block) < bytes) {
            return makeError(MediaErrorCode::CorruptData, "audio sample buffer shorter than its sample count");
        }
        std::vector<float> data(bytes / sizeof(float));
        if (CMBlockBufferCopyDataBytes(block, 0, bytes, data.data()) != kCMBlockBufferNoErr) {
            return makeError(MediaErrorCode::CorruptData, "CMBlockBufferCopyDataBytes failed");
        }
        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample.get());
        if (resampling) {
            return placeSource(data.data(), count,
                               timeToSample(pts, sourceRate, kCMTimeRoundingMethod_RoundHalfAwayFromZero));
        }
        return placeOutput(data.data(), count, timeToSample(pts, timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero));
    }

    /// The data held back after a large gap becomes current (everything before it was read).
    Status resumeAfterGap() {
        std::vector<float> held;
        held.swap(afterGap);
        haveAfterGap = false;
        const int64_t count = static_cast<int64_t>(held.size()) / channels;
        if (resampling) {
            converterStarted = false;
            return placeSource(held.data(), count, afterGapStart);
        }
        staged.swap(held);
        stagedStart = afterGapStart;
        return okStatus();
    }
};

AppleAudioDecoder::AppleAudioDecoder(double loadTimeoutSeconds) : impl_(std::make_unique<Impl>(loadTimeoutSeconds)) {}

AppleAudioDecoder::~AppleAudioDecoder() = default;

Status AppleAudioDecoder::open(const std::string &path, int trackIndex, const AudioOptions &options) {
    Impl &d = *impl_;
    if (d.opened) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (!(options.sampleRate >= 8000 && options.sampleRate <= 384000) ||
        std::floor(options.sampleRate) != options.sampleRate) {
        return makeError(MediaErrorCode::InvalidArgument, "sample rate must be an integer in 8000...384000");
    }
    if (options.channels < 1 || options.channels > 8) {
        return makeError(MediaErrorCode::InvalidArgument, "channels must be 1...8");
    }
    @autoreleasepool {
        auto loaded = loadAsset(path, d.timeout);
        if (!loaded.ok()) {
            return std::move(loaded).error();
        }
        auto track = selectTrack(loaded.value(), trackIndex, AVMediaTypeAudio, nullptr);
        if (!track.ok()) {
            return std::move(track).error();
        }
        d.asset = loaded->asset;
        d.track = track.value();
        d.rate = options.sampleRate;
        d.timescale = static_cast<int32_t>(options.sampleRate);
        d.channels = options.channels;
        d.length = d.timeToSample(CMTimeRangeGetEnd(d.track.timeRange), d.timescale,
                                  kCMTimeRoundingMethod_RoundHalfAwayFromZero);
        if (d.track.formatDescriptions.count > 0) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                (__bridge CMAudioFormatDescriptionRef)d.track.formatDescriptions.firstObject);
            if (asbd != nullptr && asbd->mSampleRate >= 1000 && asbd->mSampleRate <= 768000 &&
                std::floor(asbd->mSampleRate) == asbd->mSampleRate) {
                d.sourceRate = static_cast<int32_t>(asbd->mSampleRate);
            }
        }
        d.resampling = d.sourceRate > 0 && d.sourceRate != d.timescale;
        if (d.resampling) {
            VE_MEDIA_TRY(d.setUpResampling());
        }
        VE_MEDIA_TRY(d.startReader(0));
        d.position = 0;
        d.opened = true;
        return okStatus();
    }
}

Status AppleAudioDecoder::seek(CMTime t) {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "seek() before open()");
    }
    if (!CMTIME_IS_NUMERIC(t)) {
        return makeError(MediaErrorCode::InvalidArgument, "seek() needs a numeric time");
    }
    @autoreleasepool {
        const int64_t target = std::max<int64_t>(
            0, d.timeToSample(t, d.timescale, kCMTimeRoundingMethod_RoundTowardNegativeInfinity));
        if (d.reader != nil && target >= d.position &&
            target - d.position <= static_cast<int64_t>(kSkipAheadSeconds * d.rate)) {
            d.position = target;
            return okStatus();
        }
        d.position = target;
        Status s = d.startReader(target);
        if (!s.ok()) {
            d.stopReader();
        }
        return s;
    }
}

Result<int> AppleAudioDecoder::read(float *interleaved, int frames) {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "read() before open()");
    }
    if (frames < 0 || (frames > 0 && interleaved == nullptr)) {
        return makeError(MediaErrorCode::InvalidArgument, "read() needs a buffer");
    }
    @autoreleasepool {
        if (d.reader == nil) {
            VE_MEDIA_TRY(d.startReader(d.position));
        }
        const int ch = d.channels;
        int produced = 0;
        while (produced < frames) {
            if (d.position >= d.length && d.resampling) {
                break; // The converter may flush a few samples past the track's length.
            }
            const int64_t stagedEnd = d.stagedStart + d.stagedFrames();
            if (d.stagedFrames() > 0 && d.position < stagedEnd) {
                int64_t want = frames - produced;
                if (d.resampling) {
                    want = std::min<int64_t>(want, d.length - d.position);
                }
                if (d.position < d.stagedStart) {
                    const int64_t n = std::min<int64_t>(d.stagedStart - d.position, want);
                    std::fill_n(interleaved + static_cast<ptrdiff_t>(produced) * ch, n * ch, 0.0f);
                    produced += static_cast<int>(n);
                    d.position += n;
                    continue;
                }
                const int64_t offset = d.position - d.stagedStart;
                const int64_t n = std::min<int64_t>(stagedEnd - d.position, want);
                std::memcpy(interleaved + static_cast<ptrdiff_t>(produced) * ch, d.staged.data() + offset * ch,
                            static_cast<size_t>(n * ch) * sizeof(float));
                produced += static_cast<int>(n);
                d.position += n;
                continue;
            }
            if (d.haveAfterGap) {
                Status s = d.resumeAfterGap();
                if (!s.ok()) {
                    d.stopReader();
                    return std::move(s).error();
                }
                continue;
            }
            if (d.readerDone) {
                break;
            }
            Status s = d.fetch();
            if (!s.ok()) {
                d.stopReader();
                return std::move(s).error();
            }
        }
        return produced;
    }
}

int64_t AppleAudioDecoder::position() const {
    return impl_->position;
}

CMTime AppleAudioDecoder::positionTime() const {
    return CMTimeMake(impl_->position, impl_->timescale);
}

double AppleAudioDecoder::sampleRate() const {
    return impl_->rate;
}

int AppleAudioDecoder::channels() const {
    return impl_->channels;
}

int64_t AppleAudioDecoder::lengthFrames() const {
    return impl_->length;
}

} // namespace ve::media::apple
