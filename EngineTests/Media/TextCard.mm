#include "TextCard.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>

namespace ve::test {

namespace {

const char *const kWords[] = {
    "Framewright", "export",   "sequence", "timeline", "1080p",    "3840x2160", "Lanczos",  "quality",
    "0.95",        "Inspector", "Position", "Scale",   "Rotation", "Opacity",   "00:01:23", "Ken Burns",
    "dissolve",    "keyframe",  "render",   "preview", "H.264",    "HEVC",      "ProRes",   "29.97 fps",
    "File",        "Edit",      "View",     "Clip",    "Sequence", "Playback",  "Window",   "Help",
};
constexpr size_t kWordCount = sizeof(kWords) / sizeof(kWords[0]);

} // namespace

GrayImage renderTextCard(size_t width, size_t height, double pixelSize, bool inverted, int variant) {
    GrayImage image;
    image.width = width;
    image.height = height;
    image.pixels.assign(width * height, inverted ? 0 : 255);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(image.pixels.data(), width, height, 8, width, gray,
                                                 static_cast<uint32_t>(kCGImageAlphaNone));
    CGColorSpaceRelease(gray);
    if (context == nullptr) {
        image.pixels.clear();
        return image;
    }
    // CoreGraphics' origin is the bottom left: flip so lines run top down like a screen.
    CGContextTranslateCTM(context, 0, CGFloat(height));
    CGContextScaleCTM(context, 1, -1);
    CGContextSetShouldAntialias(context, true);
    CGContextSetShouldSmoothFonts(context, false);
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), pixelSize, nullptr);
    CGColorRef ink = CGColorCreateGenericGray(inverted ? 1.0 : 0.0, 1.0);
    const double lineHeight = std::ceil(pixelSize * 1.35);
    const double margin = std::round(pixelSize * 1.5);
    size_t word = 0;
    int line = 0;
    for (double baseline = margin + pixelSize; baseline + pixelSize * 0.4 < double(height) - margin;
         baseline += lineHeight, ++line) {
        std::string text;
        while (text.size() < size_t(double(width - 2 * size_t(margin)) / (pixelSize * 0.52))) {
            const size_t index = (word * 7 + size_t(line) * 3 + (line == 5 ? size_t(variant) : 0)) % kWordCount;
            text += kWords[index];
            text += (word % 5 == 4) ? ".  " : " ";
            ++word;
        }
        CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, text.c_str(), kCFStringEncodingUTF8);
        const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
        const void *values[] = {font, ink};
        CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                        &kCFTypeDictionaryKeyCallBacks,
                                                        &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
        CTLineRef ctLine = CTLineCreateWithAttributedString(attributed);
        // The text matrix draws upright in the flipped context.
        CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
        CGContextSetTextPosition(context, margin, baseline);
        CTLineDraw(ctLine, context);
        CFRelease(ctLine);
        CFRelease(attributed);
        CFRelease(attributes);
        CFRelease(string);
    }
    // A text cursor after the last line's first words, moving with the variant.
    CGContextSetFillColorWithColor(context, ink);
    const double cursorX = margin + double((variant * 37) % int(std::max<size_t>(1, width / 2)));
    CGContextFillRect(context, CGRectMake(cursorX, margin, std::max(1.0, pixelSize / 11.0), pixelSize * 1.1));
    CGColorRelease(ink);
    CFRelease(font);
    CGContextRelease(context);
    return image;
}

bool fillBGRA(CVPixelBufferRef bgra, const GrayImage &image) {
    if (bgra == nullptr || CVPixelBufferGetPixelFormatType(bgra) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(bgra) != image.width || CVPixelBufferGetHeight(bgra) != image.height ||
        image.pixels.size() != image.width * image.height) {
        return false;
    }
    CVPixelBufferLockBaseAddress(bgra, 0);
    auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(bgra));
    const size_t stride = CVPixelBufferGetBytesPerRow(bgra);
    for (size_t y = 0; y < image.height; ++y) {
        uint8_t *row = base + y * stride;
        for (size_t x = 0; x < image.width; ++x) {
            const uint8_t v = image.at(x, y);
            row[x * 4 + 0] = v;
            row[x * 4 + 1] = v;
            row[x * 4 + 2] = v;
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(bgra, 0);
    return true;
}

std::string writeTextCardMovie(const std::string &path, size_t width, size_t height, int frames, int framesPerSecond,
                               int64_t bitRate, double pixelSize, bool inverted, int framesPerVariant) {
    NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&error];
    if (writer == nil) {
        return std::string("AVAssetWriter: ") + (error.localizedDescription.UTF8String ?: "failed");
    }
    NSDictionary *settings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(width),
        AVVideoHeightKey : @(height),
        AVVideoCompressionPropertiesKey : @{
            AVVideoAverageBitRateKey : @(bitRate),
            AVVideoMaxKeyFrameIntervalKey : @(framesPerSecond),
            AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                   sourcePixelBufferAttributes:@{
                                       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferWidthKey : @(width),
                                       (id)kCVPixelBufferHeightKey : @(height),
                                   }];
    [writer addInput:input];
    if (![writer startWriting]) {
        return std::string("startWriting: ") + (writer.error.localizedDescription.UTF8String ?: "failed");
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    int currentVariant = -1;
    GrayImage card;
    for (int frame = 0; frame < frames; ++frame) {
        const int variant = frame / std::max(1, framesPerVariant);
        if (variant != currentVariant) {
            card = renderTextCard(width, height, pixelSize, inverted, variant);
            currentVariant = variant;
            if (card.pixels.empty()) {
                return "cannot draw the text card";
            }
        }
        while (!input.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.002];
        }
        CVPixelBufferRef buffer = nullptr;
        if (adaptor.pixelBufferPool == nil ||
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess) {
            return "no pixel buffer";
        }
        const bool filled = fillBGRA(buffer, card);
        const BOOL appended = filled && [adaptor appendPixelBuffer:buffer
                                              withPresentationTime:CMTimeMake(frame, framesPerSecond)];
        CVPixelBufferRelease(buffer);
        if (!appended) {
            return std::string("append: ") + (writer.error.localizedDescription.UTF8String ?: "fill failed");
        }
    }
    [input markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        return std::string("finish: ") + (writer.error.localizedDescription.UTF8String ?: "failed");
    }
    return {};
}

double edgeMeasure(const GrayImage &image, size_t x, size_t y, size_t w, size_t h) {
    const size_t x0 = std::max<size_t>(x, 1);
    const size_t y0 = std::max<size_t>(y, 1);
    const size_t x1 = std::min(x + w, image.width - 1);
    const size_t y1 = std::min(y + h, image.height - 1);
    double sum = 0;
    size_t count = 0;
    for (size_t j = y0; j < y1; ++j) {
        for (size_t i = x0; i < x1; ++i) {
            const double gx = (double(image.at(i + 1, j)) - double(image.at(i - 1, j))) / (2.0 * 255.0);
            const double gy = (double(image.at(i, j + 1)) - double(image.at(i, j - 1))) / (2.0 * 255.0);
            sum += std::sqrt(gx * gx + gy * gy);
            ++count;
        }
    }
    return count > 0 ? sum / double(count) : 0.0;
}

GrayImage grayOf(CVPixelBufferRef bgra) {
    GrayImage image;
    if (bgra == nullptr || CVPixelBufferGetPixelFormatType(bgra) != kCVPixelFormatType_32BGRA) {
        return image;
    }
    image.width = CVPixelBufferGetWidth(bgra);
    image.height = CVPixelBufferGetHeight(bgra);
    image.pixels.resize(image.width * image.height);
    CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(bgra));
    const size_t stride = CVPixelBufferGetBytesPerRow(bgra);
    for (size_t y = 0; y < image.height; ++y) {
        const uint8_t *row = base + y * stride;
        for (size_t x = 0; x < image.width; ++x) {
            const double luma = 0.2126 * row[x * 4 + 2] + 0.7152 * row[x * 4 + 1] + 0.0722 * row[x * 4 + 0];
            image.pixels[y * image.width + x] = uint8_t(std::clamp(std::lround(luma), 0L, 255L));
        }
    }
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    return image;
}

} // namespace ve::test
