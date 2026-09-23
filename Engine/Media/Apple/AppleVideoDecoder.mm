#include "AppleVideoDecoder.h"

#include "../CFRef.h"
#include "../ColorTags.h"
#include "../HardwareCaps.h"
#include "AppleStillImage.h"
#include "AppleSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <os/log.h>

#include <algorithm>
#include <mutex>
#include <vector>

namespace ve::media::apple {

namespace {

bool timeLess(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) < 0;
}

/// Reorder buffer bound for the random-access path: more pending frames than any real
/// stream's reorder depth means the wanted frame was dropped by the decoder.
constexpr size_t kMaxPendingFrames = 48;

os_log_t decoderLog() {
    static os_log_t log = os_log_create("ve.media.apple", "video-decode");
    return log;
}

/// Tags a decoded buffer's alpha contract and returns it for VideoFrame::alphaIsPremultiplied.
/// Video decoded by VideoToolbox with alpha (ProRes 4444) has straight alpha.
bool tagVideoAlpha(const PixelBuffer &image) {
    if (image && pixelFormatHasAlpha(image.pixelFormat())) {
        setAlphaMode(image.get(), false);
        return false;
    }
    return true;
}

Result<PixelBuffer> convertPixelFormat(const PixelBuffer &source, OSType format) {
    CFRef<VTPixelTransferSessionRef> session;
    OSStatus st = VTPixelTransferSessionCreate(kCFAllocatorDefault, session.outPtr());
    if (st != noErr) {
        return errorFromOSStatus(st, MediaErrorCode::Internal, "VTPixelTransferSessionCreate");
    }
    auto pool = PixelBufferPool::create(format, source.width(), source.height());
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    auto out = pool->makeBuffer();
    if (!out.ok()) {
        return std::move(out).error();
    }
    st = VTPixelTransferSessionTransferImage(session.get(), source.get(), out->get());
    VTPixelTransferSessionInvalidate(session.get());
    if (st != noErr) {
        return errorFromOSStatus(st, MediaErrorCode::UnsupportedFormat, "VTPixelTransferSessionTransferImage");
    }
    return std::move(out).value();
}

} // namespace

struct AppleVideoDecoder::Impl {
    enum class Mode { Idle, Sequential, RandomAccess };

    double timeout;
    bool opened = false;
    DecodeOptions options;
    std::string path;

    // Track.
    AVURLAsset *asset = nil;
    AVAssetTrack *track = nil;
    TrackInfo info;
    OSType outFormat = 0;
    int outWidth = 0; ///< 0 = native size.
    int outHeight = 0;
    CMTime frameDuration = kCMTimeInvalid;
    CMTime trackStart = kCMTimeZero;
    CMTime trackEnd = kCMTimeZero;
    bool expectHardware = false;
    bool lastHardware = false;

    // Still.
    bool isStill = false;
    PixelBuffer still;
    bool stillPending = false;

    /// The frame open() decoded, returned by the first next() unless seek() comes first.
    std::optional<VideoFrame> primed;

    // Position.
    Mode mode = Mode::Idle;
    CMTime position = kCMTimeZero;  ///< Time of the next frame the current stream should deliver.
    CMTime target = kCMTimeInvalid; ///< Frames ending at or before this are dropped.
    CMTime switchToReaderAt = kCMTimeInvalid;
    std::optional<VideoFrame> last;
    bool repeatLast = false;
    bool eos = false;

    // Sequential path.
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    /// Read-ahead: the reader's decoded frames carry no duration, so each frame is held until
    /// the next one's pts is known (see readSequential).
    std::optional<VideoFrame> seqHeld;

    /// Track-time ranges of empty edits. AVAssetReader emits a synthesized (black) frame for an
    /// empty edit; the IVideoDecoder contract instead answers a time in a gap with the first real
    /// frame after it (as the FFmpeg backend does), so those frames are dropped.
    std::vector<CMTimeRange> emptyEdits;

    // Random-access path.
    bool randomAccess = false;
    bool forceRandomAccess = false;
    CMTime mediaToTrack = kCMTimeZero; ///< track time = media time + mediaToTrack.
    AVSampleBufferGenerator *generator = nil;
    AVSampleCursor *decodeCursor = nil;  ///< Next sample to feed, decode order; nil when exhausted.
    AVSampleCursor *presentCursor = nil; ///< Next frame to emit, presentation order; nil when exhausted.
    CMTime floorPts = kCMTimeInvalid;    ///< Decoded frames before this (track time) are not needed.
    CFRef<VTDecompressionSessionRef> session;
    CFRef<CMFormatDescriptionRef> sessionFormat;
    bool sessionHardware = false;
    std::mutex pendingMutex; ///< VT may call the output callback on its own thread.
    std::vector<VideoFrame> pending;
    std::optional<MediaError> pendingError;

    explicit Impl(double t) : timeout(t) {}

    ~Impl() {
        stopReader();
        invalidateSession();
    }

    CMTime toTrack(CMTime media) const { return CMTimeAdd(media, mediaToTrack); }
    CMTime toMedia(CMTime trackTime) const { return CMTimeSubtract(trackTime, mediaToTrack); }

    bool interrupted() const { return options.interrupt && options.interrupt->requested(); }

    bool inEmptyEdit(CMTime t) const {
        return std::any_of(emptyEdits.begin(), emptyEdits.end(),
                           [&](const CMTimeRange &r) { return CMTimeRangeContainsTime(r, t); });
    }
    static MediaError cancelled() {
        return makeError(MediaErrorCode::Cancelled, "decode interrupted (DecodeOptions::interrupt)");
    }

    /// Duration of the last frame of the track: to the track end (edit lists make it exact).
    CMTime lastFrameDuration(CMTime pts, CMTime sampleDuration) const {
        const CMTime toEnd = CMTimeSubtract(trackEnd, pts);
        if (CMTIME_IS_NUMERIC(toEnd) && CMTimeCompare(toEnd, kCMTimeZero) > 0) {
            return toEnd;
        }
        if (CMTIME_IS_NUMERIC(sampleDuration) && CMTimeCompare(sampleDuration, kCMTimeZero) > 0) {
            return sampleDuration;
        }
        return frameDuration;
    }

    void stopReader() {
        if (reader != nil && reader.status == AVAssetReaderStatusReading) {
            [reader cancelReading];
        }
        reader = nil;
        output = nil;
        seqHeld.reset();
    }

    void invalidateSession() {
        if (session) {
            VTDecompressionSessionWaitForAsynchronousFrames(session.get());
            VTDecompressionSessionInvalidate(session.get());
            session.reset();
        }
        sessionFormat.reset();
    }

    NSDictionary *outputAttributes() const {
        return CFBridgingRelease(createPixelBufferAttributes(outFormat, static_cast<size_t>(outWidth),
                                                             static_cast<size_t>(outHeight)));
    }

    // MARK: Sequential path

    Status startSequential(CMTime at) {
        stopReader();
        clearRandomAccess();
        NSError *error = nil;
        AVAssetReader *r = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (r == nil) {
            return errorFromNSError(error, MediaErrorCode::DecodeFailed, "AVAssetReader init");
        }
        AVAssetReaderTrackOutput *o = nil;
        @try {
            o = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:outputAttributes()];
            o.alwaysCopiesSampleData = NO;
            if (![r canAddOutput:o]) {
                return makeError(MediaErrorCode::UnsupportedCodec, "AVAssetReader cannot add the video track output");
            }
            [r addOutput:o];
            if (CMTimeCompare(at, trackStart) > 0) {
                r.timeRange = CMTimeRangeMake(at, kCMTimePositiveInfinity);
            }
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::UnsupportedCodec,
                             "AVAssetReaderTrackOutput rejected the output settings: " + toStdString(e.reason));
        }
        if (![r startReading]) {
            return errorFromNSError(r.error, MediaErrorCode::DecodeFailed, "AVAssetReader startReading");
        }
        reader = r;
        output = o;
        mode = Mode::Sequential;
        return okStatus();
    }

    /// The next frame from the reader in presentation order with its real duration: the
    /// reader's decoded sample buffers carry no duration (kCMTimeInvalid), and the nominal frame
    /// duration is wrong for variable-rate video, so one frame is read ahead and the duration
    /// is the difference of the timestamps (the last frame lasts until the track end).
    Result<std::optional<VideoFrame>> readSequential() {
        if (!seqHeld) {
            auto first = readSequentialRaw();
            if (!first.ok()) {
                return std::move(first).error();
            }
            if (!first.value()) {
                return std::optional<VideoFrame>();
            }
            seqHeld = std::move(first).value();
        }
        auto following = readSequentialRaw();
        if (!following.ok()) {
            return std::move(following).error(); // seqHeld stays: a Cancelled call can be resumed.
        }
        VideoFrame out = std::move(*seqHeld);
        seqHeld.reset();
        if (following.value()) {
            const CMTime interval = CMTimeSubtract(following.value()->pts, out.pts);
            out.duration = CMTIME_IS_NUMERIC(interval) && CMTimeCompare(interval, kCMTimeZero) > 0
                               ? interval
                               : lastFrameDuration(out.pts, out.duration);
            seqHeld = std::move(following).value();
        } else {
            out.duration = lastFrameDuration(out.pts, out.duration);
        }
        return std::optional<VideoFrame>(std::move(out));
    }

    /// One decoded frame from the reader; duration is the sample buffer's (usually invalid).
    Result<std::optional<VideoFrame>> readSequentialRaw() {
        while (true) {
            if (interrupted()) {
                return cancelled();
            }
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
                return std::optional<VideoFrame>();
            }
            CFRef<CMSampleBufferRef> sample = CFRef<CMSampleBufferRef>::adopt(raw);
            PixelBuffer image = PixelBuffer::retainImageBuffer(CMSampleBufferGetImageBuffer(sample.get()));
            if (!image) {
                continue; // Marker buffers carry no image.
            }
            const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample.get());
            if (inEmptyEdit(pts)) {
                continue; // AVFoundation's filler for an empty edit, not a frame of the file.
            }
            VideoFrame frame;
            frame.pts = pts;
            frame.duration = CMSampleBufferGetDuration(sample.get());
            frame.image = std::move(image);
            frame.wasHardwareDecoded = expectHardware;
            frame.alphaIsPremultiplied = tagVideoAlpha(frame.image);
            return std::optional<VideoFrame>(std::move(frame));
        }
    }

    // MARK: Random-access path

    void clearRandomAccess() {
        decodeCursor = nil;
        presentCursor = nil;
        floorPts = kCMTimeInvalid;
        if (session) {
            VTDecompressionSessionWaitForAsynchronousFrames(session.get());
        }
        std::lock_guard<std::mutex> lock(pendingMutex);
        pending.clear();
        pendingError.reset();
    }

    /// sourceFrameRefCon for samples decoded only as references (never displayed).
    static constexpr uintptr_t kReferenceOnly = 1;

    static void outputCallback(void *refCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags flags,
                               CVImageBufferRef image, CMTime pts, CMTime duration) {
        auto *self = static_cast<Impl *>(refCon);
        std::lock_guard<std::mutex> lock(self->pendingMutex);
        if (reinterpret_cast<uintptr_t>(sourceFrameRefCon) == kReferenceOnly) {
            // Leading pictures of an open GOP (HEVC RASL after a CRA) reference the previous GOP
            // and fail with kVTVideoDecoderReferenceMissingErr; they precede the target and are
            // never shown, so their errors do not matter.
            return;
        }
        if (status != noErr) {
            if (!self->pendingError) {
                self->pendingError =
                    makeError(status == kVTVideoDecoderBadDataErr ? MediaErrorCode::CorruptData
                                                                  : MediaErrorCode::DecodeFailed,
                              "VTDecompressionSession output (OSStatus " + std::to_string(status) + ")", "OSStatus",
                              status);
            }
            return;
        }
        if (image == nullptr || (flags & kVTDecodeInfo_FrameDropped)) {
            return;
        }
        VideoFrame frame;
        frame.pts = self->toTrack(pts);
        frame.duration = (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(duration, kCMTimeZero) > 0)
                             ? duration
                             : self->frameDuration;
        frame.image = PixelBuffer::retainImageBuffer(image);
        frame.wasHardwareDecoded = self->sessionHardware;
        frame.alphaIsPremultiplied = tagVideoAlpha(frame.image);
        if (frame.image) {
            self->pending.push_back(std::move(frame));
        }
    }

    Status ensureSession(CMFormatDescriptionRef format) {
        if (session) {
            if (sessionFormat.get() == format ||
                (sessionFormat && CMFormatDescriptionEqual(sessionFormat.get(), format)) ||
                VTDecompressionSessionCanAcceptFormatDescription(session.get(), format)) {
                return okStatus();
            }
            invalidateSession();
        }
        NSDictionary *spec = @{
            (__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder :
                @(options.allowHardware),
        };
        VTDecompressionOutputCallbackRecord callback{&Impl::outputCallback, this};
        const OSStatus st =
            VTDecompressionSessionCreate(kCFAllocatorDefault, format, (__bridge CFDictionaryRef)spec,
                                         (__bridge CFDictionaryRef)outputAttributes(), &callback, session.outPtr());
        if (st != noErr) {
            return errorFromOSStatus(st,
                                     st == kVTCouldNotFindVideoDecoderErr ? MediaErrorCode::UnsupportedCodec
                                                                          : MediaErrorCode::DecodeFailed,
                                     "VTDecompressionSessionCreate");
        }
        sessionFormat = CFRef<CMFormatDescriptionRef>::retain(format);
        CFBooleanRef usingHW = nullptr;
        sessionHardware = false;
        if (VTSessionCopyProperty(session.get(), kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  kCFAllocatorDefault, &usingHW) == noErr &&
            usingHW != nullptr) {
            sessionHardware = CFBooleanGetValue(usingHW);
            CFRelease(usingHW);
        }
        return okStatus();
    }

    Status startRandomAccess(CMTime at) {
        stopReader();
        clearRandomAccess();
        const CMTime mediaTime = toMedia(at);
        AVSampleCursor *cursor = [track makeSampleCursorWithPresentationTimeStamp:mediaTime];
        if (cursor == nil) {
            return makeError(MediaErrorCode::DecodeFailed, "no sample cursor for the seek target");
        }
        // Settle on the sample whose presentation interval contains mediaTime.
        if (timeLess(mediaTime, cursor.presentationTimeStamp)) {
            [cursor stepInPresentationOrderByCount:-1];
        }
        for (int guard = 0; guard < 4; ++guard) {
            const CMTime duration = cursor.currentSampleDuration;
            if (!CMTIME_IS_NUMERIC(duration) ||
                timeLess(mediaTime, CMTimeAdd(cursor.presentationTimeStamp, duration)) ||
                [cursor stepInPresentationOrderByCount:1] == 0) {
                break;
            }
        }
        presentCursor = [cursor copy];

        // Decode from the closest full sync sample at or before the target in PRESENTATION
        // order. For closed GOPs that is the GOP's IDR; for open GOPs (HEVC CRA), a target
        // among the leading pictures of a CRA is presented before it and so starts from the
        // previous sync sample, whose GOP those pictures reference.
        AVSampleCursor *start = [cursor copy];
        while (!start.currentSampleSyncInfo.sampleIsFullSync) {
            if ([start stepInPresentationOrderByCount:-1] == 0) {
                break; // First sample of the track; decoding from here is the best possible.
            }
        }
        const NSInteger refresh = start.samplesRequiredForDecoderRefresh;
        if (refresh > 0) {
            [start stepInDecodeOrderByCount:-refresh];
        }
        decodeCursor = start;
        floorPts = toTrack(presentCursor.presentationTimeStamp);
        mode = Mode::RandomAccess;
        return okStatus();
    }

    Status waitForData(CMSampleBufferRef sample) {
        if (CMSampleBufferDataIsReady(sample)) {
            return okStatus();
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *readyError = nil;
        __block BOOL ready = NO;
        [AVSampleBufferGenerator notifyOfDataReadyForSampleBuffer:sample
                                                completionHandler:^(BOOL dataReady, NSError *error) {
                                                    ready = dataReady;
                                                    readyError = error;
                                                    dispatch_semaphore_signal(done);
                                                }];
        const dispatch_time_t deadline =
            dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeout * static_cast<double>(NSEC_PER_SEC)));
        if (dispatch_semaphore_wait(done, deadline) != 0) {
            return makeError(MediaErrorCode::Timeout, "sample data was not loaded in time");
        }
        if (!ready) {
            return errorFromNSError(readyError, MediaErrorCode::CorruptData, "loading sample data");
        }
        return okStatus();
    }

    Status decodeNextSample() {
        AVSampleBufferRequest *request = [[AVSampleBufferRequest alloc] initWithStartCursor:decodeCursor];
        request.direction = AVSampleBufferRequestDirectionForward;
        request.maxSampleCount = 1;
        request.mode = AVSampleBufferRequestModeImmediate;
        NSError *error = nil;
        CFRef<CMSampleBufferRef> sample =
            CFRef<CMSampleBufferRef>::adopt([generator createSampleBufferForRequest:request error:&error]);
        if ([decodeCursor stepInDecodeOrderByCount:1] == 0) {
            decodeCursor = nil;
        }
        if (!sample) {
            return errorFromNSError(error, MediaErrorCode::CorruptData, "AVSampleBufferGenerator");
        }
        VE_MEDIA_TRY(waitForData(sample.get()));
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample.get());
        if (format == nullptr) {
            return makeError(MediaErrorCode::CorruptData, "sample without format description");
        }
        VE_MEDIA_TRY(ensureSession(format));
        const CMTime pts = toTrack(CMSampleBufferGetPresentationTimeStamp(sample.get()));
        VTDecodeFrameFlags flags = 0;
        void *frameRefCon = nullptr;
        const bool referenceOnly = CMTIME_IS_NUMERIC(floorPts) && CMTIME_IS_NUMERIC(pts) && timeLess(pts, floorPts);
        if (referenceOnly) {
            flags |= kVTDecodeFrame_DoNotOutputFrame; // Decoded for reference, never displayed.
            frameRefCon = reinterpret_cast<void *>(kReferenceOnly);
        }
        VTDecodeInfoFlags infoOut = 0;
        OSStatus st = VTDecompressionSessionDecodeFrame(session.get(), sample.get(), flags, frameRefCon, &infoOut);
        if (st == kVTInvalidSessionErr) {
            // The session died (e.g. GPU reset). Recreate once and retry.
            invalidateSession();
            VE_MEDIA_TRY(ensureSession(format));
            st = VTDecompressionSessionDecodeFrame(session.get(), sample.get(), flags, frameRefCon, &infoOut);
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session.get());
        if (referenceOnly && st == kVTVideoDecoderReferenceMissingErr) {
            st = noErr; // See outputCallback.
        }
        if (st != noErr) {
            return errorFromOSStatus(st,
                                     st == kVTVideoDecoderBadDataErr ? MediaErrorCode::CorruptData
                                                                     : MediaErrorCode::DecodeFailed,
                                     "VTDecompressionSessionDecodeFrame");
        }
        std::lock_guard<std::mutex> lock(pendingMutex);
        if (pendingError) {
            MediaError e = std::move(*pendingError);
            pendingError.reset();
            return e;
        }
        return okStatus();
    }

    Result<std::optional<VideoFrame>> readRandomAccess() {
        while (true) {
            if (interrupted()) {
                return cancelled();
            }
            if (presentCursor == nil) {
                return std::optional<VideoFrame>();
            }
            const CMTime want = toTrack(presentCursor.presentationTimeStamp);
            if (CMTimeCompare(want, trackEnd) >= 0) {
                return std::optional<VideoFrame>();
            }
            std::optional<VideoFrame> found;
            size_t pendingCount = 0;
            {
                std::lock_guard<std::mutex> lock(pendingMutex);
                // Frames before `want` can no longer be emitted in order.
                pending.erase(std::remove_if(pending.begin(), pending.end(),
                                             [&](const VideoFrame &f) { return timeLess(f.pts, want); }),
                              pending.end());
                auto it = std::find_if(pending.begin(), pending.end(),
                                       [&](const VideoFrame &f) { return CMTimeCompare(f.pts, want) == 0; });
                if (it != pending.end()) {
                    found = std::move(*it);
                    pending.erase(it);
                }
                pendingCount = pending.size();
            }
            if (found || decodeCursor == nil || pendingCount > kMaxPendingFrames) {
                // Advance past `want`: either it is emitted now, or it can never arrive (decoder
                // exhausted or dropped it) and is skipped.
                if ([presentCursor stepInPresentationOrderByCount:1] == 0) {
                    presentCursor = nil;
                }
                floorPts = presentCursor ? toTrack(presentCursor.presentationTimeStamp) : trackEnd;
                if (!found) {
                    os_log_error(decoderLog(),
                                 "frame at %.6f s never came out of VideoToolbox (%zu frames pending, %{public}s); "
                                 "skipped",
                                 CMTimeGetSeconds(want), pendingCount,
                                 decodeCursor == nil ? "no samples left to decode" : "reorder window exceeded");
                    if (decodeCursor == nil && pendingCount == 0 && presentCursor == nil) {
                        return std::optional<VideoFrame>();
                    }
                    continue;
                }
                // Display interval: up to the next frame in presentation order (the output
                // callback's duration is the sample's decode-order duration), the last frame to
                // the track end.
                const CMTime nextPts = presentCursor ? floorPts : trackEnd;
                const CMTime interval = CMTimeSubtract(nextPts, found->pts);
                if (CMTIME_IS_NUMERIC(interval) && CMTimeCompare(interval, kCMTimeZero) > 0) {
                    found->duration = interval;
                } else {
                    found->duration = lastFrameDuration(found->pts, found->duration);
                }
                maybeScheduleReaderHandOver();
                return found;
            }
            VE_MEDIA_TRY(decodeNextSample());
        }
    }

    /// After a random-access seek, return to the pipelined AVAssetReader at the next GOP
    /// boundary, where handing over wastes no decoding.
    void maybeScheduleReaderHandOver() {
        if (forceRandomAccess || decodeCursor == nil || presentCursor == nil) {
            return;
        }
        if (decodeCursor.currentSampleSyncInfo.sampleIsFullSync) {
            switchToReaderAt = toTrack(presentCursor.presentationTimeStamp);
        }
    }

    // MARK: Positioning

    /// Positions either path at `at`. On failure nothing is left half-started: mode is Idle
    /// (no reader, no cursors) and the target is `at`, so the next next() retries this seek
    /// instead of reporting a silent end of stream from a stopped reader.
    Status startAt(CMTime at) {
        eos = false;
        switchToReaderAt = kCMTimeInvalid;
        Status s = okStatus();
        if (randomAccess || forceRandomAccess) {
            s = startRandomAccess(at);
            if (!s.ok() && !forceRandomAccess) {
                os_log_info(decoderLog(), "random-access start at %.6f s failed (%{public}s); using AVAssetReader",
                            CMTimeGetSeconds(at), s.error().description().c_str());
                s = startSequential(at);
            }
        } else {
            s = startSequential(at);
        }
        target = at;
        position = at;
        if (!s.ok()) {
            stopReader();
            clearRandomAccess();
            mode = Mode::Idle;
        }
        return s;
    }
};

AppleVideoDecoder::AppleVideoDecoder(double loadTimeoutSeconds) : impl_(std::make_unique<Impl>(loadTimeoutSeconds)) {}

AppleVideoDecoder::~AppleVideoDecoder() = default;

Status AppleVideoDecoder::open(const std::string &path, int trackIndex, const DecodeOptions &options) {
    Impl &d = *impl_;
    if (d.opened) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (options.maxDimension < 0) {
        return makeError(MediaErrorCode::InvalidArgument, "maxDimension must be >= 0");
    }
    @autoreleasepool {
        (void)HardwareCaps::get(); // Registers the supplemental AV1/VP9 decoders before any VT use.
        d.options = options;
        d.path = path;

        auto still = probeStillImage(path);
        if (!still.ok()) {
            return std::move(still).error();
        }
        if (still.value()) {
            if (trackIndex > 0) {
                return makeError(MediaErrorCode::NoSuchTrack, "still images have one track (0)");
            }
            auto image = decodeStillImage(path, options.maxDimension);
            if (!image.ok()) {
                return std::move(image).error();
            }
            PixelBuffer buffer = std::move(image).value();
            if (options.pixelFormat != 0 && options.pixelFormat != buffer.pixelFormat()) {
                auto converted = convertPixelFormat(buffer, options.pixelFormat);
                if (!converted.ok()) {
                    return std::move(converted).error();
                }
                buffer = std::move(converted).value();
            }
            d.info = still.value()->tracks.front();
            d.isStill = true;
            d.still = std::move(buffer);
            d.outFormat = d.still.pixelFormat();
            d.stillPending = true;
            d.opened = true;
            return okStatus();
        }

        auto loaded = loadAsset(path, d.timeout);
        if (!loaded.ok()) {
            return std::move(loaded).error();
        }
        int resolved = -1;
        auto track = selectTrack(loaded.value(), trackIndex, AVMediaTypeVideo, &resolved);
        if (!track.ok()) {
            return std::move(track).error();
        }
        d.asset = loaded->asset;
        d.track = track.value();
        if (d.track.formatDescriptions.count == 0) {
            return makeError(MediaErrorCode::CorruptData, "video track has no format description");
        }
        d.info = makeTrackInfo(d.track, resolved);
        const VideoFormatDetails details =
            videoFormatDetails((__bridge CMFormatDescriptionRef)d.track.formatDescriptions.firstObject);
        d.outFormat = options.pixelFormat != 0 ? options.pixelFormat : nativePixelFormat(details);
        if (options.maxDimension > 0) {
            int w = details.width;
            int h = details.height;
            fitDimensions(options.maxDimension, w, h);
            if (w != details.width || h != details.height) {
                d.outWidth = w;
                d.outHeight = h;
            }
        }
        d.frameDuration = d.info.frameDuration;
        const CMTimeRange range = d.track.timeRange;
        d.trackStart = range.start;
        d.trackEnd = CMTimeRangeGetEnd(range);
        if (!CMTIME_IS_NUMERIC(d.trackEnd) || CMTimeCompare(d.trackEnd, d.trackStart) <= 0) {
            return makeError(MediaErrorCode::CorruptData, "video track has no duration");
        }
        // Measured, not predicted: AVAssetReader does not say which decoder it uses, so ask
        // VideoToolbox about a session for this exact format (AVAssetReader drives the same
        // VideoToolbox with hardware preferred). A format VideoToolbox refuses fails here,
        // where the router can still fall back to another backend.
        // makeTrackInfo measured with hardware allowed; measure again only for a software-only
        // decoder or to report why the format is refused.
        if (!d.info.decodable || !options.allowHardware) {
            auto measured =
                measureHardwareDecode((__bridge CMFormatDescriptionRef)d.track.formatDescriptions.firstObject,
                                      options.allowHardware);
            if (!measured.ok()) {
                return std::move(measured).error();
            }
            if (!d.info.decodable) {
                return makeError(MediaErrorCode::UnsupportedCodec, "AVFoundation reports the video track of " + path +
                                                                       " as not playable/decodable");
            }
            d.expectHardware = measured.value();
        } else {
            d.expectHardware = d.info.hardwareDecode;
        }
        d.lastHardware = d.expectHardware;

        // Random access needs sample cursors and a single rate-1 media segment in the edit list.
        bool mappable = true;
        int mediaSegments = 0;
        for (AVAssetTrackSegment *segment in d.track.segments) {
            if (segment.empty) {
                d.emptyEdits.push_back(segment.timeMapping.target);
                continue;
            }
            const CMTimeMapping m = segment.timeMapping;
            if (++mediaSegments > 1 || CMTimeCompare(m.source.duration, m.target.duration) != 0) {
                mappable = false;
                continue; // Keep collecting empty edits.
            }
            d.mediaToTrack = CMTimeSubtract(m.target.start, m.source.start);
        }
        d.randomAccess = mappable && d.track.canProvideSampleCursors;
        if (d.randomAccess) {
            d.generator = [[AVSampleBufferGenerator alloc] initWithAsset:d.asset timebase:nil];
            d.randomAccess = d.generator != nil;
        }
        if (!options.allowHardware) {
            if (!d.randomAccess) {
                return makeError(MediaErrorCode::UnsupportedCodec,
                                 "software-only decode needs sample cursors, which this file does not provide");
            }
            d.forceRandomAccess = true;
        }
        // Playback from the start: the pipelined reader, unless software decode was demanded.
        if (d.forceRandomAccess) {
            VE_MEDIA_TRY(d.startRandomAccess(d.trackStart));
        } else {
            VE_MEDIA_TRY(d.startSequential(d.trackStart));
        }
        d.position = d.trackStart;
        d.target = kCMTimeInvalid;
        d.opened = true;
        // Decode the first frame now (kept for the first next()): streams VideoToolbox accepts
        // at session creation but cannot decode fail here rather than in the first next().
        auto first = next();
        if (!first.ok()) {
            d.opened = false;
            d.stopReader();
            d.clearRandomAccess();
            return std::move(first).error();
        }
        d.primed = std::move(first).value();
        return okStatus();
    }
}

Status AppleVideoDecoder::seek(CMTime t) {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "seek() before open()");
    }
    if (!CMTIME_IS_NUMERIC(t)) {
        return makeError(MediaErrorCode::InvalidArgument, "seek() needs a numeric time");
    }
    if (d.isStill) {
        d.stillPending = true;
        return okStatus();
    }
    @autoreleasepool {
        d.primed.reset();
        d.repeatLast = false;
        if (timeLess(t, d.trackStart)) {
            t = d.trackStart;
        }
        if (CMTimeCompare(t, d.trackEnd) >= 0) {
            d.eos = true;
            return okStatus();
        }
        d.eos = false;
        if (d.last && d.last->contains(t) && d.mode != Impl::Mode::Idle) {
            // The frame is already in hand and the stream continues right after it.
            d.repeatLast = true;
            d.target = kCMTimeInvalid;
            return okStatus();
        }
        if (d.mode != Impl::Mode::Idle && CMTimeCompare(t, d.position) >= 0 &&
            CMTimeGetSeconds(CMTimeSubtract(t, d.position)) <= kCloseAheadSeconds) {
            d.target = t;
            d.position = t;
            return okStatus();
        }
        d.last.reset();
        Status s = d.startAt(t);
        if (!s.ok()) {
            // The next next() retries the seek to t (not a stale earlier target).
            d.mode = Impl::Mode::Idle;
            d.target = t;
            d.position = t;
        }
        return s;
    }
}

Result<std::optional<VideoFrame>> AppleVideoDecoder::next() {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "next() before open()");
    }
    if (d.isStill) {
        if (!d.stillPending) {
            return std::optional<VideoFrame>();
        }
        d.stillPending = false;
        VideoFrame frame;
        frame.pts = kCMTimeZero;
        frame.duration = kCMTimePositiveInfinity;
        frame.image = d.still;
        frame.wasHardwareDecoded = false;
        frame.alphaIsPremultiplied = alphaIsPremultiplied(frame.image.get(), true);
        d.lastHardware = false;
        return std::optional<VideoFrame>(std::move(frame));
    }
    if (d.primed) {
        VideoFrame frame = std::move(*d.primed);
        d.primed.reset();
        return std::optional<VideoFrame>(std::move(frame));
    }
    if (d.eos) {
        return std::optional<VideoFrame>();
    }
    if (d.repeatLast && d.last) {
        d.repeatLast = false;
        return d.last;
    }
    @autoreleasepool {
        if (CMTIME_IS_VALID(d.switchToReaderAt)) {
            const CMTime at = d.switchToReaderAt;
            d.switchToReaderAt = kCMTimeInvalid;
            Status reader = d.startSequential(at);
            if (reader.ok()) {
                if (!CMTIME_IS_VALID(d.target) || timeLess(d.target, at)) {
                    d.target = at;
                }
            } else {
                // Keep going on a fresh random-access decode from the same point.
                os_log_info(decoderLog(), "hand-over to AVAssetReader at %.6f s failed (%{public}s); staying on "
                                          "the random-access path", CMTimeGetSeconds(at),
                            reader.error().description().c_str());
                Status random = d.startRandomAccess(at);
                if (!random.ok()) {
                    // Neither path could start: leave no half-initialised cursors behind; the
                    // next call starts over at the same point.
                    d.clearRandomAccess();
                    d.mode = Impl::Mode::Idle;
                    d.target = at;
                    d.position = at;
                    return std::move(random).error();
                }
                if (!CMTIME_IS_VALID(d.target) || timeLess(d.target, at)) {
                    d.target = at;
                }
            }
        }
        if (d.mode == Impl::Mode::Idle) {
            const CMTime resume = CMTIME_IS_VALID(d.target) ? d.target : d.position;
            VE_MEDIA_TRY(d.startAt(resume));
        }
        while (true) {
            if (d.interrupted()) {
                return Impl::cancelled(); // State kept: the next call continues toward the target.
            }
            auto r = d.mode == Impl::Mode::Sequential ? d.readSequential() : d.readRandomAccess();
            if (!r.ok()) {
                if (r.error().code == MediaErrorCode::Cancelled) {
                    return std::move(r).error(); // Resumable: nothing was lost.
                }
                d.stopReader();
                d.clearRandomAccess();
                d.mode = Impl::Mode::Idle;
                return std::move(r).error();
            }
            if (!r.value() || CMTimeCompare(r.value()->pts, d.trackEnd) >= 0) {
                d.eos = true;
                return std::optional<VideoFrame>();
            }
            VideoFrame &frame = *r.value();
            if (CMTIME_IS_VALID(d.target) && CMTimeCompare(CMTimeAdd(frame.pts, frame.duration), d.target) <= 0) {
                continue;
            }
            d.target = kCMTimeInvalid;
            d.position = CMTimeAdd(frame.pts, frame.duration);
            d.lastHardware = frame.wasHardwareDecoded;
            d.last = frame;
            return std::move(r).value();
        }
    }
}

CMTime AppleVideoDecoder::frameDuration() const {
    return impl_->frameDuration;
}

bool AppleVideoDecoder::supportsRandomAccess() const {
    return impl_->isStill || impl_->randomAccess;
}

bool AppleVideoDecoder::usedHardware() const {
    return impl_->lastHardware;
}

OSType AppleVideoDecoder::outputPixelFormat() const {
    return impl_->outFormat;
}

bool AppleVideoDecoder::isOnRandomAccessPath() const {
    return impl_->mode == Impl::Mode::RandomAccess;
}

} // namespace ve::media::apple
