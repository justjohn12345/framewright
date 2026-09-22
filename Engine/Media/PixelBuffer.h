// RAII wrapper for CVPixelBufferRef and a pool that produces Metal/IOSurface compatible buffers.
#pragma once

#include "CFRef.h"
#include "Result.h"

#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <utility>

namespace ve::media {

/// Shared owner of one CVPixelBufferRef.
///
/// Ref-counted rather than move-only: a decoded frame is routinely held by several parties at
/// once (frame cache, render thread, encoder, thumbnail service) and CVPixelBuffer is already
/// a thread-safe ref-counted object, so copying a PixelBuffer is exactly one atomic CFRetain,
/// the same cost as copying a std::shared_ptr, without a second heap allocation or a second
/// ownership layer. Moves transfer without touching the reference count.
///
/// Thread-safety: like std::shared_ptr. Distinct PixelBuffer objects may be copied and
/// destroyed concurrently even if they share a buffer. Buffers returned by decoders are
/// immutable by convention: lock them read-only (kCVPixelBufferLock_ReadOnly) and never write.
class PixelBuffer {
  public:
    PixelBuffer() noexcept = default;
    PixelBuffer(std::nullptr_t) noexcept {}

    /// Takes ownership of a +1 reference.
    static PixelBuffer adopt(CVPixelBufferRef buffer) noexcept {
        PixelBuffer p;
        p.ref_ = CFRef<CVPixelBufferRef>::adopt(buffer);
        return p;
    }
    /// Retains a +0 reference.
    static PixelBuffer retain(CVPixelBufferRef buffer) noexcept {
        PixelBuffer p;
        p.ref_ = CFRef<CVPixelBufferRef>::retain(buffer);
        return p;
    }
    /// Retains the image buffer if it is a CVPixelBuffer; empty otherwise.
    static PixelBuffer retainImageBuffer(CVImageBufferRef image) noexcept {
        if (image == nullptr || CFGetTypeID(image) != CVPixelBufferGetTypeID()) {
            return {};
        }
        return retain(static_cast<CVPixelBufferRef>(image));
    }

    CVPixelBufferRef get() const noexcept { return ref_.get(); }
    explicit operator bool() const noexcept { return static_cast<bool>(ref_); }
    /// Gives up ownership; the caller must release the returned +1 reference.
    CVPixelBufferRef detach() noexcept { return ref_.detach(); }
    void reset() noexcept { ref_.reset(); }

    size_t width() const noexcept { return ref_ ? CVPixelBufferGetWidth(ref_.get()) : 0; }
    size_t height() const noexcept { return ref_ ? CVPixelBufferGetHeight(ref_.get()) : 0; }
    OSType pixelFormat() const noexcept { return ref_ ? CVPixelBufferGetPixelFormatType(ref_.get()) : 0; }
    bool isIOSurfaceBacked() const noexcept { return ref_ && CVPixelBufferGetIOSurface(ref_.get()) != nullptr; }

    friend bool operator==(const PixelBuffer &a, const PixelBuffer &b) noexcept { return a.get() == b.get(); }

  private:
    CFRef<CVPixelBufferRef> ref_;
};

/// Scoped CVPixelBufferLockBaseAddress / Unlock.
class PixelBufferLock {
  public:
    PixelBufferLock(CVPixelBufferRef buffer, bool readOnly) noexcept
        : buffer_(buffer), flags_(readOnly ? kCVPixelBufferLock_ReadOnly : 0) {
        locked_ = buffer_ && CVPixelBufferLockBaseAddress(buffer_, flags_) == kCVReturnSuccess;
    }
    ~PixelBufferLock() {
        if (locked_) {
            CVPixelBufferUnlockBaseAddress(buffer_, flags_);
        }
    }
    PixelBufferLock(const PixelBufferLock &) = delete;
    PixelBufferLock &operator=(const PixelBufferLock &) = delete;
    bool locked() const noexcept { return locked_; }

  private:
    CVPixelBufferRef buffer_;
    CVPixelBufferLockFlags flags_;
    bool locked_ = false;
};

/// Pixel buffer attributes used for every buffer the media layer allocates or requests from a
/// decoder: IOSurface backed (zero-copy to Metal through CVMetalTextureCache) and Metal
/// compatible. width/height of 0 are omitted (decoder chooses). Returns a +1 dictionary.
CFDictionaryRef createPixelBufferAttributes(OSType pixelFormat, size_t width, size_t height);

/// CVPixelBufferPool of IOSurface-backed, Metal compatible buffers of one size and format.
/// Thread-safety: makeBuffer() may be called from any thread concurrently (CVPixelBufferPool
/// is thread-safe).
class PixelBufferPool {
  public:
    PixelBufferPool() = default;
    static Result<PixelBufferPool> create(OSType pixelFormat, size_t width, size_t height);

    Result<PixelBuffer> makeBuffer() const;
    explicit operator bool() const noexcept { return static_cast<bool>(pool_); }
    OSType pixelFormat() const noexcept { return format_; }
    size_t width() const noexcept { return width_; }
    size_t height() const noexcept { return height_; }

  private:
    CFRef<CVPixelBufferPoolRef> pool_;
    OSType format_ = 0;
    size_t width_ = 0;
    size_t height_ = 0;
};

} // namespace ve::media
