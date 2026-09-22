#include "AppleSupport.h"

#include "../ColorTags.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>

namespace ve::media::apple {

std::string toStdString(NSString *string) {
    return string ? std::string(string.UTF8String ?: "") : std::string();
}

MediaError errorFromNSError(NSError *error, MediaErrorCode fallback, const std::string &context) {
    if (error == nil) {
        return makeError(fallback, context + ": unknown error");
    }
    MediaErrorCode code = fallback;
    NSString *domain = error.domain;
    const NSInteger c = error.code;
    if ([domain isEqualToString:AVFoundationErrorDomain]) {
        switch (c) {
        case AVErrorFileFormatNotRecognized:
        case AVErrorContentIsNotAuthorized:
        case AVErrorContentIsProtected:
            code = MediaErrorCode::UnsupportedFormat;
            break;
        case AVErrorDecoderNotFound:
        case AVErrorEncoderNotFound:
        case AVErrorDecoderTemporarilyUnavailable:
        case AVErrorEncoderTemporarilyUnavailable:
        case AVErrorFormatUnsupported:
            code = MediaErrorCode::UnsupportedCodec;
            break;
        case AVErrorFailedToParse:
        case AVErrorFileFailedToParse:
        case AVErrorNoDataCaptured:
            code = MediaErrorCode::CorruptData;
            break;
        case AVErrorOperationCancelled:
            code = MediaErrorCode::Cancelled;
            break;
        case AVErrorDiskFull:
        case AVErrorOutOfMemory:
        case AVErrorNoLongerPlayable:
            break;
        default:
            break;
        }
    } else if ([domain isEqualToString:NSCocoaErrorDomain]) {
        if (c == NSFileNoSuchFileError || c == NSFileReadNoSuchFileError) {
            code = MediaErrorCode::FileNotFound;
        } else if (c == NSFileReadNoPermissionError || c == NSFileWriteNoPermissionError) {
            code = MediaErrorCode::PermissionDenied;
        } else if (c == NSFileReadCorruptFileError) {
            code = MediaErrorCode::CorruptData;
        }
    } else if ([domain isEqualToString:NSURLErrorDomain]) {
        if (c == NSURLErrorFileDoesNotExist) {
            code = MediaErrorCode::FileNotFound;
        } else if (c == NSURLErrorNoPermissionsToReadFile) {
            code = MediaErrorCode::PermissionDenied;
        } else if (c == NSURLErrorCannotDecodeContentData || c == NSURLErrorCannotParseResponse) {
            code = MediaErrorCode::CorruptData;
        }
    }
    std::string message = context + ": " + toStdString(error.localizedDescription);
    if (NSString *reason = error.localizedFailureReason) {
        message += " (" + toStdString(reason) + ")";
    }
    if (NSError *underlying = error.userInfo[NSUnderlyingErrorKey]) {
        message += " underlying " + toStdString(underlying.domain) + " " + std::to_string(underlying.code);
    }
    return makeError(code, message, toStdString(domain), static_cast<int64_t>(c));
}

MediaError errorFromOSStatus(OSStatus status, MediaErrorCode code, const std::string &context) {
    return makeError(code, context + " failed (OSStatus " + std::to_string(status) + ")", "OSStatus", status);
}

NSURL *fileURL(const std::string &path) {
    return [NSURL fileURLWithPath:@(path.c_str()) isDirectory:NO];
}

Status checkReadableFile(const std::string &path) {
    if (path.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "empty path");
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    NSString *p = @(path.c_str());
    if (p == nil) {
        return makeError(MediaErrorCode::InvalidArgument, "path is not valid UTF-8");
    }
    if (![fm fileExistsAtPath:p isDirectory:&isDirectory]) {
        return makeError(MediaErrorCode::FileNotFound, "no such file: " + path);
    }
    if (isDirectory) {
        return makeError(MediaErrorCode::UnsupportedFormat, "is a directory: " + path);
    }
    if (![fm isReadableFileAtPath:p]) {
        return makeError(MediaErrorCode::PermissionDenied, "not readable: " + path);
    }
    return okStatus();
}

Status loadValues(id<AVAsynchronousKeyValueLoading> object, NSArray<NSString *> *keys, double timeoutSeconds,
                  const std::string &what, NSSet<NSString *> *optionalKeys) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [object loadValuesAsynchronouslyForKeys:keys
                          completionHandler:^{
                              dispatch_semaphore_signal(done);
                          }];
    const dispatch_time_t deadline =
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeoutSeconds * static_cast<double>(NSEC_PER_SEC)));
    if (dispatch_semaphore_wait(done, deadline) != 0) {
        if ([(id)object isKindOfClass:AVAsset.class]) {
            [(AVAsset *)object cancelLoading];
        }
        return makeError(MediaErrorCode::Timeout, what + ": loading timed out");
    }
    for (NSString *key in keys) {
        NSError *error = nil;
        const AVKeyValueStatus status = [object statusOfValueForKey:key error:&error];
        const bool optional = [optionalKeys containsObject:key];
        if (status == AVKeyValueStatusLoaded || (status == AVKeyValueStatusFailed && optional)) {
            continue;
        }
        if (status == AVKeyValueStatusCancelled) {
            return makeError(MediaErrorCode::Cancelled, what + ": loading '" + toStdString(key) + "' cancelled");
        }
        return errorFromNSError(error, MediaErrorCode::UnsupportedFormat,
                                what + ": cannot load '" + toStdString(key) + "'");
    }
    return okStatus();
}

Result<LoadedAsset> loadAsset(const std::string &path, double timeoutSeconds) {
    VE_MEDIA_TRY(checkReadableFile(path));
    LoadedAsset loaded;
    loaded.asset = [AVURLAsset URLAssetWithURL:fileURL(path)
                                       options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
    if (loaded.asset == nil) {
        return makeError(MediaErrorCode::UnsupportedFormat, "AVURLAsset could not be created for " + path);
    }
    VE_MEDIA_TRY(loadValues(loaded.asset, @[ @"tracks", @"duration" ], timeoutSeconds, path));
    loaded.tracks = loaded.asset.tracks;
    NSArray<NSString *> *trackKeys = @[
        @"formatDescriptions", @"timeRange", @"nominalFrameRate", @"minFrameDuration", @"naturalSize",
        @"preferredTransform", @"segments", @"naturalTimeScale", @"canProvideSampleCursors"
    ];
    // Only the format and time range are essential; the rest have safe defaults (0, identity,
    // no cursors) and some formats cannot provide them.
    NSSet<NSString *> *optional =
        [NSSet setWithArray:[trackKeys subarrayWithRange:NSMakeRange(2, trackKeys.count - 2)]];
    for (AVAssetTrack *track in loaded.tracks) {
        VE_MEDIA_TRY(loadValues(track, trackKeys, timeoutSeconds, path + " track " + std::to_string(track.trackID),
                                optional));
    }
    return loaded;
}

Result<AVAssetTrack *> selectTrack(const LoadedAsset &loaded, int trackIndex, AVMediaType mediaType,
                                   int *resolvedIndex) {
    NSArray<AVAssetTrack *> *tracks = loaded.tracks;
    if (trackIndex < 0) {
        for (NSUInteger i = 0; i < tracks.count; ++i) {
            if ([tracks[i].mediaType isEqualToString:mediaType]) {
                if (resolvedIndex) {
                    *resolvedIndex = static_cast<int>(i);
                }
                return tracks[i];
            }
        }
        return makeError(MediaErrorCode::NoSuchTrack, "no " + toStdString(mediaType) + " track");
    }
    if (static_cast<NSUInteger>(trackIndex) >= tracks.count) {
        return makeError(MediaErrorCode::NoSuchTrack, "track index " + std::to_string(trackIndex) + " out of range");
    }
    AVAssetTrack *track = tracks[static_cast<NSUInteger>(trackIndex)];
    if (![track.mediaType isEqualToString:mediaType]) {
        return makeError(MediaErrorCode::NoSuchTrack, "track " + std::to_string(trackIndex) + " is " +
                                                          toStdString(track.mediaType) + ", not " +
                                                          toStdString(mediaType));
    }
    if (resolvedIndex) {
        *resolvedIndex = trackIndex;
    }
    return track;
}

namespace {

NSData *sampleDescriptionAtom(CMFormatDescriptionRef format, NSString *name) {
    NSDictionary *atoms = (__bridge NSDictionary *)CMFormatDescriptionGetExtension(
        format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    id value = [atoms isKindOfClass:NSDictionary.class] ? atoms[name] : nil;
    if ([value isKindOfClass:NSArray.class]) {
        value = [(NSArray *)value firstObject];
    }
    return [value isKindOfClass:NSData.class] ? (NSData *)value : nil;
}

ChromaSubsampling chromaFromIdc(int idc) {
    switch (idc) {
    case 1:
        return ChromaSubsampling::C420;
    case 2:
        return ChromaSubsampling::C422;
    case 3:
        return ChromaSubsampling::C444;
    default:
        return ChromaSubsampling::C420; // 0 = monochrome: decoded as 4:2:0 with neutral chroma.
    }
}

// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 8.3.3.1): chroma_format_idc in byte 16,
// bit_depth_luma_minus8 in byte 17.
void parseHvcC(NSData *hvcC, VideoFormatDetails &d) {
    if (hvcC.length < 19) {
        return;
    }
    const uint8_t *b = static_cast<const uint8_t *>(hvcC.bytes);
    d.chroma = chromaFromIdc(b[16] & 0x3);
    d.bitDepth = (b[17] & 0x7) + 8;
}

// AVCDecoderConfigurationRecord (ISO/IEC 14496-15 5.3.3.1): for High profiles the chroma format
// and bit depth follow the SPS/PPS arrays; otherwise the stream is 8-bit 4:2:0.
void parseAvcC(NSData *avcC, VideoFormatDetails &d) {
    const size_t n = avcC.length;
    if (n < 7) {
        return;
    }
    const uint8_t *b = static_cast<const uint8_t *>(avcC.bytes);
    const int profile = b[1];
    size_t pos = 5;
    const int numSPS = b[pos++] & 0x1F;
    for (int i = 0; i < numSPS; ++i) {
        if (pos + 2 > n) {
            return;
        }
        pos += 2 + ((size_t(b[pos]) << 8) | b[pos + 1]);
    }
    if (pos >= n) {
        return;
    }
    const int numPPS = b[pos++];
    for (int i = 0; i < numPPS; ++i) {
        if (pos + 2 > n) {
            return;
        }
        pos += 2 + ((size_t(b[pos]) << 8) | b[pos + 1]);
    }
    const bool highProfile = profile == 100 || profile == 110 || profile == 122 || profile == 144 || profile == 244;
    if (highProfile && pos + 2 <= n) {
        d.chroma = chromaFromIdc(b[pos] & 0x3);
        d.bitDepth = (b[pos + 1] & 0x7) + 8;
    } else if (profile == 110) {
        d.bitDepth = 10;
    } else if (profile == 122) {
        d.bitDepth = 10;
        d.chroma = ChromaSubsampling::C422;
    } else if (profile == 244) {
        d.bitDepth = 10;
        d.chroma = ChromaSubsampling::C444;
    }
}

int intExtension(CMFormatDescriptionRef format, CFStringRef key, int fallback) {
    CFTypeRef v = CMFormatDescriptionGetExtension(format, key);
    int out = fallback;
    if (v != nullptr && CFGetTypeID(v) == CFNumberGetTypeID() &&
        CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberIntType, &out)) {
        return out;
    }
    return fallback;
}

} // namespace

VideoFormatDetails videoFormatDetails(CMFormatDescriptionRef format) {
    VideoFormatDetails d;
    if (format == nullptr) {
        return d;
    }
    d.codec = CMFormatDescriptionGetMediaSubType(format);
    const CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format);
    d.width = dims.width;
    d.height = dims.height;
    d.color = colorInfoFromAttachments(CMFormatDescriptionGetExtensions(format));
    CFTypeRef fullRange = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_FullRangeVideo);
    d.color.fullRange = fullRange != nullptr && CFGetTypeID(fullRange) == CFBooleanGetTypeID() &&
                        CFBooleanGetValue(static_cast<CFBooleanRef>(fullRange));

    const uint32_t codec = canonicalCodec(d.codec);
    if (codec == fourcc::HEVC) {
        parseHvcC(sampleDescriptionAtom(format, @"hvcC"), d);
    } else if (codec == fourcc::H264) {
        parseAvcC(sampleDescriptionAtom(format, @"avcC"), d);
    } else if (isProRes(codec)) {
        const bool is4444 = codec == fourcc::ProRes4444 || codec == fourcc::ProRes4444XQ;
        d.chroma = is4444 ? ChromaSubsampling::C444 : ChromaSubsampling::C422;
        d.bitDepth = is4444 ? 12 : 10;
        d.hasAlpha = is4444 && intExtension(format, kCMFormatDescriptionExtension_Depth, 24) == 32;
    }
    const int bpc = intExtension(format, kCMFormatDescriptionExtension_BitsPerComponent, 0);
    if (bpc > 0) {
        d.bitDepth = bpc;
    }
    return d;
}

OSType nativePixelFormat(const VideoFormatDetails &d) {
    const bool full = d.color.fullRange;
    if (d.hasAlpha) {
        return kCVPixelFormatType_32BGRA;
    }
    switch (d.chroma) {
    case ChromaSubsampling::C422:
        return full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    case ChromaSubsampling::C444:
        return full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
    case ChromaSubsampling::C420:
    case ChromaSubsampling::Unknown:
        break;
    }
    if (d.bitDepth > 8) {
        return full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    }
    return full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

namespace {

int rotationFromTransform(CGAffineTransform t) {
    const double degrees = std::atan2(t.b, t.a) * 180.0 / M_PI;
    int r = static_cast<int>(std::lround(degrees / 90.0)) * 90;
    r = ((r % 360) + 360) % 360;
    return r;
}

} // namespace

TrackInfo makeTrackInfo(AVAssetTrack *track, int index) {
    TrackInfo info;
    info.index = index;
    info.startTime = track.timeRange.start;
    info.duration = track.timeRange.duration;
    CMFormatDescriptionRef format = nullptr;
    if (track.formatDescriptions.count > 0) {
        format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    }
    if ([track.mediaType isEqualToString:AVMediaTypeVideo]) {
        info.kind = TrackKind::Video;
        const VideoFormatDetails d = videoFormatDetails(format);
        info.codec = {d.codec, codecDisplayName(d.codec)};
        info.width = d.width;
        info.height = d.height;
        info.bitDepth = d.bitDepth;
        info.chroma = d.chroma;
        info.color = d.color;
        info.rotationDegrees = rotationFromTransform(track.preferredTransform);
        info.nominalFps = track.nominalFrameRate;
        const CMTime minDuration = track.minFrameDuration;
        if (CMTIME_IS_NUMERIC(minDuration) && CMTimeCompare(minDuration, kCMTimeZero) > 0) {
            info.frameDuration = minDuration;
        } else if (info.nominalFps > 0) {
            const int32_t ts = track.naturalTimeScale > 0 ? track.naturalTimeScale : 600;
            info.frameDuration = CMTimeMake(std::llround(ts / info.nominalFps), ts);
        }
        if (info.nominalFps > 0 && CMTIME_IS_NUMERIC(info.frameDuration)) {
            const double nominal = 1.0 / info.nominalFps;
            const double minimum = CMTimeGetSeconds(info.frameDuration);
            info.isVFR = std::fabs(minimum - nominal) / nominal > 0.01;
        }
    } else if ([track.mediaType isEqualToString:AVMediaTypeAudio]) {
        info.kind = TrackKind::Audio;
        const uint32_t codec = format ? CMFormatDescriptionGetMediaSubType(format) : 0;
        info.codec = {codec, codecDisplayName(codec)};
        if (const AudioStreamBasicDescription *asbd =
                format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : nullptr) {
            info.sampleRate = asbd->mSampleRate;
            info.channels = static_cast<int>(asbd->mChannelsPerFrame);
        }
    }
    return info;
}

namespace {
bool bytesEqual(const uint8_t *p, const char *s, size_t n) {
    return std::memcmp(p, s, n) == 0;
}
} // namespace

std::string sniffContainer(const std::string &path) {
    uint8_t b[512] = {};
    size_t n = 0;
    {
        std::ifstream in(path, std::ios::binary);
        in.read(reinterpret_cast<char *>(b), sizeof b);
        n = static_cast<size_t>(std::max<std::streamsize>(in.gcount(), 0));
    }
    if (n >= 12 && bytesEqual(b + 4, "ftyp", 4)) {
        const uint8_t *brand = b + 8;
        if (bytesEqual(brand, "qt  ", 4)) {
            return "mov";
        }
        if (bytesEqual(brand, "M4A ", 4) || bytesEqual(brand, "M4B ", 4)) {
            return "m4a";
        }
        if (bytesEqual(brand, "M4V", 3)) {
            return "m4v";
        }
        if (bytesEqual(brand, "heic", 4) || bytesEqual(brand, "heix", 4) || bytesEqual(brand, "mif1", 4) ||
            bytesEqual(brand, "msf1", 4)) {
            return "heic";
        }
        if (bytesEqual(brand, "avif", 4)) {
            return "avif";
        }
        return "mp4";
    }
    if (n >= 8 && (bytesEqual(b + 4, "moov", 4) || bytesEqual(b + 4, "mdat", 4) || bytesEqual(b + 4, "wide", 4) ||
                   bytesEqual(b + 4, "free", 4) || bytesEqual(b + 4, "skip", 4) || bytesEqual(b + 4, "pnot", 4))) {
        return "mov";
    }
    if (n >= 12 && (bytesEqual(b, "RIFF", 4) || bytesEqual(b, "RF64", 4))) {
        if (bytesEqual(b + 8, "WAVE", 4)) {
            return "wav";
        }
        if (bytesEqual(b + 8, "AVI ", 4)) {
            return "avi";
        }
    }
    if (n >= 12 && bytesEqual(b, "FORM", 4) && (bytesEqual(b + 8, "AIFF", 4) || bytesEqual(b + 8, "AIFC", 4))) {
        return "aiff";
    }
    if (n >= 4 && bytesEqual(b, "caff", 4)) {
        return "caf";
    }
    if (n >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
        for (size_t i = 0; i + 4 <= n; ++i) {
            if (bytesEqual(b + i, "webm", 4)) {
                return "webm";
            }
        }
        return "mkv";
    }
    if (n >= 8 && b[0] == 0x89 && bytesEqual(b + 1, "PNG", 3)) {
        return "png";
    }
    if (n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
        return "jpeg";
    }
    if (n >= 4 && bytesEqual(b, "GIF8", 4)) {
        return "gif";
    }
    if (n >= 4 && (bytesEqual(b, "II*\0", 4) || bytesEqual(b, "MM\0*", 4))) {
        return "tiff";
    }
    if (n >= 189 && b[0] == 0x47 && b[188] == 0x47) {
        return "mpegts";
    }
    if (n >= 3 && (bytesEqual(b, "ID3", 3) || (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0))) {
        return "mp3";
    }
    NSString *ext = @(path.c_str()).pathExtension.lowercaseString;
    return toStdString(ext);
}

NSData *channelLayoutData(int channels) {
    AudioChannelLayout layout{};
    if (channels == 1) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    } else if (channels == 2) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    } else {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | static_cast<UInt32>(channels);
    }
    return [NSData dataWithBytes:&layout length:sizeof layout];
}

void fitDimensions(int maxDimension, int &width, int &height) {
    if (maxDimension <= 0 || width <= 0 || height <= 0 || (width <= maxDimension && height <= maxDimension)) {
        return;
    }
    const double scale = static_cast<double>(maxDimension) / std::max(width, height);
    width = std::max(2, static_cast<int>(std::lround(width * scale / 2.0)) * 2);
    height = std::max(2, static_cast<int>(std::lround(height * scale / 2.0)) * 2);
}

} // namespace ve::media::apple
