#include "PixelBuffer.h"

#import <Foundation/Foundation.h>

#include <string>

namespace ve::media {

CFDictionaryRef createPixelBufferAttributes(OSType pixelFormat, size_t width, size_t height) {
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (pixelFormat != 0) {
        attrs[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] = @(pixelFormat);
    }
    attrs[(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    attrs[(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey] = @YES;
    if (width > 0 && height > 0) {
        attrs[(__bridge NSString *)kCVPixelBufferWidthKey] = @(width);
        attrs[(__bridge NSString *)kCVPixelBufferHeightKey] = @(height);
    }
    return (CFDictionaryRef)CFBridgingRetain([attrs copy]);
}

Result<PixelBufferPool> PixelBufferPool::create(OSType pixelFormat, size_t width, size_t height) {
    if (pixelFormat == 0 || width == 0 || height == 0) {
        return makeError(MediaErrorCode::InvalidArgument, "PixelBufferPool: format and size must be non-zero");
    }
    CFRef<CFDictionaryRef> attrs =
        CFRef<CFDictionaryRef>::adopt(createPixelBufferAttributes(pixelFormat, width, height));
    PixelBufferPool pool;
    const CVReturn rc = CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, attrs.get(), pool.pool_.outPtr());
    if (rc != kCVReturnSuccess || !pool.pool_) {
        return makeError(MediaErrorCode::Internal,
                         "CVPixelBufferPoolCreate failed for " + std::to_string(width) + "x" + std::to_string(height),
                         "CVReturn", rc);
    }
    pool.format_ = pixelFormat;
    pool.width_ = width;
    pool.height_ = height;
    return pool;
}

Result<PixelBuffer> PixelBufferPool::makeBuffer() const {
    if (!pool_) {
        return makeError(MediaErrorCode::InvalidState, "PixelBufferPool: not created");
    }
    CVPixelBufferRef buffer = nullptr;
    const CVReturn rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool_.get(), &buffer);
    if (rc != kCVReturnSuccess || buffer == nullptr) {
        return makeError(MediaErrorCode::Internal, "CVPixelBufferPoolCreatePixelBuffer failed", "CVReturn", rc);
    }
    return PixelBuffer::adopt(buffer);
}

} // namespace ve::media
