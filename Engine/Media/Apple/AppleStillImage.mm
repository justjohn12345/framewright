#include "AppleStillImage.h"

#include "../CFRef.h"
#include "../ColorTags.h"
#include "../Interfaces.h"
#include "AppleSupport.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>

namespace ve::media::apple {

namespace {

struct ImageHeader {
    int width = 0;  ///< Oriented (display) width.
    int height = 0; ///< Oriented (display) height.
    uint32_t codec = 0;
    std::string container;
};

int intProperty(NSDictionary *props, CFStringRef key) {
    id v = props[(__bridge NSString *)key];
    return [v isKindOfClass:NSNumber.class] ? [(NSNumber *)v intValue] : 0;
}

void describeType(NSString *uti, ImageHeader &h) {
    UTType *type = uti ? [UTType typeWithIdentifier:uti] : nil;
    if ([type conformsToType:UTTypePNG]) {
        h.codec = fourcc::PNG;
        h.container = "png";
    } else if ([type conformsToType:UTTypeJPEG]) {
        h.codec = fourcc::JPEG;
        h.container = "jpeg";
    } else if ([type conformsToType:UTTypeHEIC] || [type conformsToType:UTTypeHEIF]) {
        h.codec = fourcc::HEIC;
        h.container = "heic";
    } else if ([type conformsToType:UTTypeTIFF]) {
        h.codec = fourcc::make("tiff");
        h.container = "tiff";
    } else if ([type conformsToType:UTTypeGIF]) {
        h.codec = fourcc::make("gif ");
        h.container = "gif";
    } else {
        h.codec = fourcc::make("imag");
        h.container = type.preferredFilenameExtension ? toStdString(type.preferredFilenameExtension) : "image";
    }
}

// nullopt = not an image. Error = image that cannot be read.
Result<std::optional<ImageHeader>> readHeader(CGImageSourceRef source) {
    NSString *uti = (__bridge NSString *)CGImageSourceGetType(source);
    if (uti == nil) {
        return std::optional<ImageHeader>();
    }
    UTType *type = [UTType typeWithIdentifier:uti];
    if (type == nil || ![type conformsToType:UTTypeImage]) {
        return std::optional<ImageHeader>();
    }
    if (CGImageSourceGetCount(source) < 1) {
        return makeError(MediaErrorCode::CorruptData, "image contains no frames");
    }
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    ImageHeader h;
    h.width = intProperty(props, kCGImagePropertyPixelWidth);
    h.height = intProperty(props, kCGImagePropertyPixelHeight);
    if (h.width <= 0 || h.height <= 0) {
        return makeError(MediaErrorCode::CorruptData, "image has no size");
    }
    const int orientation = intProperty(props, kCGImagePropertyOrientation);
    if (orientation >= 5 && orientation <= 8) {
        std::swap(h.width, h.height);
    }
    describeType(uti, h);
    return std::optional<ImageHeader>(h);
}

CFRef<CGImageSourceRef> openSource(const std::string &path) {
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCache : @NO};
    return CFRef<CGImageSourceRef>::adopt(
        CGImageSourceCreateWithURL((__bridge CFURLRef)fileURL(path), (__bridge CFDictionaryRef)options));
}

} // namespace

Result<std::optional<MediaInfo>> probeStillImage(const std::string &path) {
    @autoreleasepool {
        VE_MEDIA_TRY(checkReadableFile(path));
        CFRef<CGImageSourceRef> source = openSource(path);
        if (!source) {
            return std::optional<MediaInfo>();
        }
        auto header = readHeader(source.get());
        if (!header.ok()) {
            return std::move(header).error();
        }
        if (!header.value()) {
            return std::optional<MediaInfo>();
        }
        const ImageHeader &h = *header.value();
        MediaInfo info;
        info.path = path;
        info.container = h.container;
        info.duration = kCMTimeIndefinite;
        TrackInfo track;
        track.index = 0;
        track.kind = TrackKind::Still;
        track.codec = {h.codec, codecDisplayName(h.codec)};
        track.width = h.width;
        track.height = h.height;
        track.bitDepth = 8;
        track.color = {ColorPrimaries::BT709, TransferFunction::SRGB, YCbCrMatrix::Unknown, true};
        track.duration = kCMTimeIndefinite;
        info.tracks.push_back(track);
        return std::optional<MediaInfo>(std::move(info));
    }
}

Result<PixelBuffer> decodeStillImage(const std::string &path, int maxDimension) {
    @autoreleasepool {
        VE_MEDIA_TRY(checkReadableFile(path));
        CFRef<CGImageSourceRef> source = openSource(path);
        if (!source) {
            return makeError(MediaErrorCode::UnsupportedFormat, "ImageIO cannot open " + path);
        }
        auto header = readHeader(source.get());
        if (!header.ok()) {
            return std::move(header).error();
        }
        if (!header.value()) {
            return makeError(MediaErrorCode::UnsupportedFormat, "not an image: " + path);
        }
        int width = header.value()->width;
        int height = header.value()->height;
        fitDimensions(maxDimension > 0 ? std::min(maxDimension, kMaxImageDimension) : kMaxImageDimension, width,
                      height);
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(std::max(width, height)),
            (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
        };
        CFRef<CGImageRef> image = CFRef<CGImageRef>::adopt(
            CGImageSourceCreateThumbnailAtIndex(source.get(), 0, (__bridge CFDictionaryRef)options));
        if (!image) {
            return makeError(MediaErrorCode::CorruptData, "ImageIO failed to decode " + path);
        }
        // Use the decoded image's size: ImageIO may round the scaled size differently.
        width = static_cast<int>(CGImageGetWidth(image.get()));
        height = static_cast<int>(CGImageGetHeight(image.get()));

        auto pool = PixelBufferPool::create(kCVPixelFormatType_32BGRA, static_cast<size_t>(width),
                                            static_cast<size_t>(height));
        if (!pool.ok()) {
            return std::move(pool).error();
        }
        auto buffer = pool->makeBuffer();
        if (!buffer.ok()) {
            return std::move(buffer).error();
        }
        CVPixelBufferRef pb = buffer->get();
        {
            PixelBufferLock lock(pb, false);
            if (!lock.locked()) {
                return makeError(MediaErrorCode::Internal, "CVPixelBufferLockBaseAddress failed");
            }
            CFRef<CGColorSpaceRef> srgb = CFRef<CGColorSpaceRef>::adopt(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
            CFRef<CGContextRef> ctx = CFRef<CGContextRef>::adopt(CGBitmapContextCreate(
                CVPixelBufferGetBaseAddress(pb), static_cast<size_t>(width), static_cast<size_t>(height), 8,
                CVPixelBufferGetBytesPerRow(pb), srgb.get(),
                static_cast<uint32_t>(kCGImageAlphaPremultipliedFirst) |
                    static_cast<uint32_t>(kCGBitmapByteOrder32Little)));
            if (!ctx) {
                return makeError(MediaErrorCode::Internal, "CGBitmapContextCreate failed");
            }
            CGContextSetBlendMode(ctx.get(), kCGBlendModeCopy);
            CGContextDrawImage(ctx.get(), CGRectMake(0, 0, width, height), image.get());
            CFRef<CFDataRef> icc = CFRef<CFDataRef>::adopt(CGColorSpaceCopyICCData(srgb.get()));
            if (icc) {
                CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, icc.get(), kCVAttachmentMode_ShouldPropagate);
            }
        }
        attachColorInfo(pb, {ColorPrimaries::BT709, TransferFunction::SRGB, YCbCrMatrix::Unknown, true});
        setAlphaMode(pb, true); // CoreGraphics drew premultiplied (kCGImageAlphaPremultipliedFirst).
        return std::move(buffer).value();
    }
}

} // namespace ve::media::apple
