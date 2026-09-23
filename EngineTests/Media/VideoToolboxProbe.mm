#include "VideoToolboxProbe.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

namespace ve::test {

std::optional<bool> videoToolboxDecodesInHardware(const std::string &path) {
    @autoreleasepool {
        // EngineTests does not link AVFoundation itself (the engine framework does, so the
        // classes are loaded): look the class up at run time. AVMediaTypeVideo is "vide".
        Class assetClass = NSClassFromString(@"AVURLAsset");
        if (assetClass == nil) {
            return std::nullopt;
        }
        AVURLAsset *asset = [assetClass URLAssetWithURL:[NSURL fileURLWithPath:@(path.c_str())] options:nil];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSArray<AVAssetTrack *> *tracks = nil;
        [asset loadTracksWithMediaType:@"vide"
                     completionHandler:^(NSArray<AVAssetTrack *> *loaded, NSError *) {
                         tracks = loaded;
                         dispatch_semaphore_signal(done);
                     }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0 ||
            tracks.count == 0) {
            return std::nullopt;
        }
        AVAssetTrack *track = tracks.firstObject;
        __block NSArray *formats = nil;
        [track loadValuesAsynchronouslyForKeys:@[ @"formatDescriptions" ]
                             completionHandler:^{
                                 dispatch_semaphore_signal(done);
                             }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
            return std::nullopt;
        }
        formats = track.formatDescriptions;
        if (formats.count == 0) {
            return std::nullopt;
        }
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)formats.firstObject;
        NSDictionary *spec = @{(__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder : @YES};
        VTDecompressionSessionRef session = nullptr;
        if (VTDecompressionSessionCreate(kCFAllocatorDefault, format, (__bridge CFDictionaryRef)spec, nullptr, nullptr,
                                         &session) != noErr ||
            session == nullptr) {
            return std::nullopt;
        }
        CFBooleanRef hw = nullptr;
        bool result = false;
        if (VTSessionCopyProperty(session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  kCFAllocatorDefault, &hw) == noErr &&
            hw != nullptr) {
            result = CFBooleanGetValue(hw);
            CFRelease(hw);
        }
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
        return result;
    }
}

bool videoToolboxEncodesInHardware(CMVideoCodecType codec, int width, int height) {
    NSDictionary *spec = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES,
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES,
    };
    VTCompressionSessionRef session = nullptr;
    const OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, codec,
                                                   (__bridge CFDictionaryRef)spec, nullptr, kCFAllocatorDefault,
                                                   nullptr, nullptr, &session);
    if (st != noErr || session == nullptr) {
        return false;
    }
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    return true;
}

} // namespace ve::test
