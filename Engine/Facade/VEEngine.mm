#import "VEEngine.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
}

@implementation VEEngine

+ (NSString *)engineVersion {
    NSBundle *bundle = [NSBundle bundleForClass:self];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSAssert(version.length > 0, @"VidEditEngine.framework Info.plist has no CFBundleShortVersionString");
    return version;
}

+ (NSString *)ffmpegVersion {
    return @(av_version_info());
}

+ (NSString *)ffmpegLicense {
    return @(avcodec_license());
}

@end
