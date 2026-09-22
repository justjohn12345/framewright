#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Entry point of the engine for the Swift UI layer.
@interface VEEngine : NSObject

/// Engine version, from the framework's CFBundleShortVersionString (e.g. "0.1.0").
/// Not named `version`: NSObject already has `+ (NSInteger)version` (NSCoder class versioning).
@property (class, nonatomic, readonly, copy) NSString *engineVersion;

/// Version of the FFmpeg libraries the engine is running against (av_version_info(), e.g. "7.1.5").
@property (class, nonatomic, readonly, copy) NSString *ffmpegVersion;

/// License string reported by the loaded libavcodec (avcodec_license()).
@property (class, nonatomic, readonly, copy) NSString *ffmpegLicense;

@end

NS_ASSUME_NONNULL_END
