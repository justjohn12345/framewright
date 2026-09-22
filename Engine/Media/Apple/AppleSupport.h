// Shared helpers for the AVFoundation backend (Objective-C++ only).
#pragma once

#import <AVFoundation/AVFoundation.h>

#include "../MediaTypes.h"
#include "../Result.h"

#include <string>

namespace ve::media::apple {

/// Default upper bound for blocking on AVFoundation's asynchronous property loading.
constexpr double kDefaultLoadTimeoutSeconds = 10.0;

MediaError errorFromNSError(NSError *error, MediaErrorCode fallback, const std::string &context);
MediaError errorFromOSStatus(OSStatus status, MediaErrorCode code, const std::string &context);
std::string toStdString(NSString *string);

/// FileNotFound / PermissionDenied / InvalidArgument for paths that cannot be opened.
Status checkReadableFile(const std::string &path);
NSURL *fileURL(const std::string &path);

/// Loads `keys` through AVAsynchronousKeyValueLoading and blocks until they are loaded, failed
/// or `timeoutSeconds` elapsed (then loading is cancelled when `object` is an AVAsset). Keys in
/// `optionalKeys` may fail to load (their getters then return defaults); the others must load.
Status loadValues(id<AVAsynchronousKeyValueLoading> object, NSArray<NSString *> *keys, double timeoutSeconds,
                  const std::string &what, NSSet<NSString *> *optionalKeys = nil);

/// An AVURLAsset whose tracks and every per-track property this backend reads are loaded.
struct LoadedAsset {
    AVURLAsset *asset = nil;
    NSArray<AVAssetTrack *> *tracks = nil;
};
Result<LoadedAsset> loadAsset(const std::string &path, double timeoutSeconds);

/// Resolves a TrackInfo::index (position in asset.tracks) or -1 (first track of `mediaType`).
Result<AVAssetTrack *> selectTrack(const LoadedAsset &loaded, int trackIndex, AVMediaType mediaType,
                                   int *resolvedIndex);

/// Describes a loaded track (video or audio) as a TrackInfo.
TrackInfo makeTrackInfo(AVAssetTrack *track, int index);

/// Details of a video format description needed to pick native output formats.
struct VideoFormatDetails {
    uint32_t codec = 0;
    int width = 0;
    int height = 0;
    int bitDepth = 8;
    ChromaSubsampling chroma = ChromaSubsampling::C420;
    bool hasAlpha = false;
    ColorInfo color;
};
VideoFormatDetails videoFormatDetails(CMFormatDescriptionRef format);
/// The decoder-native biplanar output format for a source (see DecodeOptions::pixelFormat).
OSType nativePixelFormat(const VideoFormatDetails &details);

/// Short container token from the file's leading bytes ("mov", "mp4", "m4a", "wav", ...), or
/// from the extension when the content is not recognised.
std::string sniffContainer(const std::string &path);

/// AudioChannelLayout (Mono, Stereo, or DiscreteInOrder for more channels) for AV settings.
NSData *channelLayoutData(int channels);

/// Scales (w, h) to fit maxDimension (if > 0), preserving aspect ratio, even dimensions.
void fitDimensions(int maxDimension, int &width, int &height);

} // namespace ve::media::apple
