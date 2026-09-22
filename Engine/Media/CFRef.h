// Minimal RAII owner for Core Foundation style objects (CFTypeRef and the CF-based
// CoreMedia/CoreVideo/VideoToolbox types).
#pragma once

#include <CoreFoundation/CoreFoundation.h>

#include <utility>

namespace ve::media {

/// Owns one reference to a CF object. Copy retains, move transfers, destruction releases.
/// Thread-safety: like std::shared_ptr; distinct CFRef objects referring to the same CF object
/// may be used concurrently, a single CFRef object may not be mutated concurrently.
template <class T> class CFRef {
  public:
    CFRef() noexcept = default;
    CFRef(std::nullptr_t) noexcept {}
    ~CFRef() { reset(); }

    /// Takes ownership of a +1 reference (from a Create/Copy function).
    static CFRef adopt(T ref) noexcept {
        CFRef r;
        r.ref_ = ref;
        return r;
    }
    /// Retains a +0 reference (from a Get function).
    static CFRef retain(T ref) noexcept {
        CFRef r;
        r.ref_ = ref;
        if (ref) {
            CFRetain(ref);
        }
        return r;
    }

    CFRef(const CFRef &other) noexcept : ref_(other.ref_) {
        if (ref_) {
            CFRetain(ref_);
        }
    }
    CFRef(CFRef &&other) noexcept : ref_(std::exchange(other.ref_, nullptr)) {}
    CFRef &operator=(const CFRef &other) noexcept {
        if (this != &other) {
            CFRef copy(other);
            swap(copy);
        }
        return *this;
    }
    CFRef &operator=(CFRef &&other) noexcept {
        if (this != &other) {
            reset();
            ref_ = std::exchange(other.ref_, nullptr);
        }
        return *this;
    }

    T get() const noexcept { return ref_; }
    explicit operator bool() const noexcept { return ref_ != nullptr; }

    /// For Create/Copy functions with an out parameter. Releases the current object first.
    T *outPtr() noexcept {
        reset();
        return &ref_;
    }
    /// Gives up ownership; the caller must release the returned +1 reference.
    T detach() noexcept { return std::exchange(ref_, nullptr); }
    void reset() noexcept {
        if (ref_) {
            CFRelease(ref_);
            ref_ = nullptr;
        }
    }
    void swap(CFRef &other) noexcept { std::swap(ref_, other.ref_); }

  private:
    T ref_ = nullptr;
};

} // namespace ve::media
