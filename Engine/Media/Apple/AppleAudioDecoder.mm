#include "AppleAudioDecoder.h"

#include "../CFRef.h"
#include "AppleSupport.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace ve::media::apple {

struct AppleAudioDecoder::Impl {
    double timeout;
    bool opened = false;
    double rate = 48000;
    int32_t timescale = 48000; ///< Integral rate used as CMTime timescale for sample positions.
    int channels = 2;
    int64_t length = 0;

    AVURLAsset *asset = nil;
    AVAssetTrack *track = nil;
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    bool readerDone = false;
    bool formatChecked = false;

    int64_t position = 0;          ///< Next sample frame read() returns.
    std::vector<float> staged;     ///< Decoded frames starting at stagedStart.
    int64_t stagedStart = 0;
    int64_t streamContinuation = -1; ///< Expected start of the next buffer, -1 if unknown.

    explicit Impl(double t) : timeout(t) {}
    ~Impl() { stopReader(); }

    int64_t stagedFrames() const { return static_cast<int64_t>(staged.size()) / channels; }

    int64_t timeToSample(CMTime t, CMTimeRoundingMethod rounding) const {
        return CMTimeConvertScale(t, timescale, rounding).value;
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
            AVSampleRateKey : @(rate),
            AVNumberOfChannelsKey : @(channels),
            AVChannelLayoutKey : channelLayoutData(channels),
        };
    }

    Status startReader(int64_t atSample) {
        stopReader();
        staged.clear();
        stagedStart = 0;
        streamContinuation = -1;
        readerDone = false;
        const int64_t start = std::max<int64_t>(0, atSample - static_cast<int64_t>(kPrerollSeconds * rate));
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
            if (start > 0) {
                r.timeRange = CMTimeRangeMake(CMTimeMake(start, timescale), kCMTimePositiveInfinity);
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
        if (asbd == nullptr || asbd->mFormatID != kAudioFormatLinearPCM ||
            !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) ||
            (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) || asbd->mBitsPerChannel != 32 ||
            static_cast<int>(asbd->mChannelsPerFrame) != channels || std::fabs(asbd->mSampleRate - rate) > 0.5) {
            return makeError(MediaErrorCode::Internal, "AVAssetReader delivered an unexpected PCM format");
        }
        formatChecked = true;
        return okStatus();
    }

    /// Appends the next decoded buffer to `staged` (discarding what is already consumed).
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
        int64_t start = timeToSample(CMSampleBufferGetPresentationTimeStamp(sample.get()),
                                     kCMTimeRoundingMethod_RoundHalfAwayFromZero);
        if (streamContinuation >= 0 && std::llabs(start - streamContinuation) <= 1) {
            start = streamContinuation; // Timestamp rounding jitter, not a real gap.
        }
        streamContinuation = start + count;

        // Drop what has been consumed; if the new buffer does not continue `staged`, what is left
        // of `staged` stays in front of it (the gap is zero-filled by read()).
        const int64_t consumed = std::clamp<int64_t>(position - stagedStart, 0, stagedFrames());
        if (consumed > 0) {
            staged.erase(staged.begin(), staged.begin() + consumed * channels);
            stagedStart += consumed;
        }
        if (staged.empty()) {
            stagedStart = start;
        } else if (start != stagedStart + stagedFrames()) {
            const int64_t gap = start - (stagedStart + stagedFrames());
            if (gap > 0) {
                staged.insert(staged.end(), static_cast<size_t>(gap * channels), 0.0f);
            } else {
                // Overlap: keep the earlier data, drop the overlapping part of the new buffer.
                const int64_t skip = std::min<int64_t>(-gap, count);
                std::vector<float> tmp(bytes / sizeof(float));
                if (CMBlockBufferCopyDataBytes(block, 0, bytes, tmp.data()) != kCMBlockBufferNoErr) {
                    return makeError(MediaErrorCode::CorruptData, "CMBlockBufferCopyDataBytes failed");
                }
                staged.insert(staged.end(), tmp.begin() + skip * channels, tmp.end());
                return okStatus();
            }
        }
        const size_t old = staged.size();
        staged.resize(old + bytes / sizeof(float));
        if (CMBlockBufferCopyDataBytes(block, 0, bytes, staged.data() + old) != kCMBlockBufferNoErr) {
            staged.resize(old);
            return makeError(MediaErrorCode::CorruptData, "CMBlockBufferCopyDataBytes failed");
        }
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
        d.length = d.timeToSample(CMTimeRangeGetEnd(d.track.timeRange), kCMTimeRoundingMethod_RoundHalfAwayFromZero);
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
        const int64_t target =
            std::max<int64_t>(0, d.timeToSample(t, kCMTimeRoundingMethod_RoundTowardNegativeInfinity));
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
            const int64_t stagedEnd = d.stagedStart + d.stagedFrames();
            if (d.stagedFrames() > 0 && d.position < stagedEnd) {
                if (d.position < d.stagedStart) {
                    const int64_t n = std::min<int64_t>(d.stagedStart - d.position, frames - produced);
                    std::fill_n(interleaved + static_cast<ptrdiff_t>(produced) * ch, n * ch, 0.0f);
                    produced += static_cast<int>(n);
                    d.position += n;
                    continue;
                }
                const int64_t offset = d.position - d.stagedStart;
                const int64_t n = std::min<int64_t>(stagedEnd - d.position, frames - produced);
                std::memcpy(interleaved + static_cast<ptrdiff_t>(produced) * ch, d.staged.data() + offset * ch,
                            static_cast<size_t>(n * ch) * sizeof(float));
                produced += static_cast<int>(n);
                d.position += n;
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
