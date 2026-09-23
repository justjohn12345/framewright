// Error and result types for the media layer. No exceptions cross the media
// interfaces: every fallible call returns Result<T> (or Result<void>).
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>

namespace ve::media {

enum class MediaErrorCode {
    InvalidArgument,   ///< Caller passed an invalid value (bad track index, zero size, invalid CMTime...).
    InvalidState,      ///< Call not allowed in the object's current state (not opened, already finished...).
    FileNotFound,      ///< The path does not exist.
    PermissionDenied,  ///< The path exists but cannot be read or written.
    UnsupportedFormat, ///< The container or file type is not handled by this backend.
    UnsupportedCodec,  ///< The container is fine but the codec (or requested settings) cannot be handled.
    NoSuchTrack,       ///< The requested track index does not exist or has the wrong kind.
    CorruptData,       ///< The file is damaged or truncated.
    DecodeFailed,      ///< The decoder reported an error for otherwise well-formed input.
    EncodeFailed,      ///< The encoder rejected a frame or failed.
    WriteFailed,       ///< Muxing or file output failed.
    Timeout,           ///< An operation that is internally asynchronous did not complete in time.
    Cancelled,         ///< The operation was cancelled.
    Internal,          ///< Unexpected failure of the platform or library.
};

const char *toString(MediaErrorCode code) noexcept;

/// Errors that say nothing lasting about the media (a load that timed out, an interrupted or
/// cancelled operation): worth retrying later, not worth caching.
inline bool isTransient(MediaErrorCode code) noexcept {
    return code == MediaErrorCode::Timeout || code == MediaErrorCode::Cancelled;
}

struct MediaError {
    MediaErrorCode code = MediaErrorCode::Internal;
    std::string message;    ///< Human-readable context ("AVAssetReader startReading: ...").
    std::string domain;     ///< Underlying error domain (NSError domain, "OSStatus", "FFmpeg"), may be empty.
    int64_t underlying = 0; ///< Underlying error code in `domain` (NSError code, OSStatus, AVERROR), 0 if none.

    /// "<code>: <message> [<domain> <underlying>]".
    std::string description() const;
};

inline MediaError makeError(MediaErrorCode code, std::string message, std::string domain = {},
                            int64_t underlying = 0) {
    return MediaError{code, std::move(message), std::move(domain), underlying};
}

/// Holds either a T or a MediaError. Accessing value() of an error result (or error() of a
/// success) is a programming error and traps.
template <class T> class [[nodiscard]] Result {
  public:
    static_assert(!std::is_same_v<std::decay_t<T>, MediaError>, "Result<MediaError> is ambiguous");

    Result(MediaError error) : storage_(std::in_place_index<1>, std::move(error)) {}
    template <class U = T,
              std::enable_if_t<std::is_constructible_v<T, U &&> &&
                                   !std::is_same_v<std::decay_t<U>, MediaError> &&
                                   !std::is_same_v<std::decay_t<U>, Result>,
                               int> = 0>
    Result(U &&value) : storage_(std::in_place_index<0>, std::forward<U>(value)) {}

    bool ok() const noexcept { return storage_.index() == 0; }
    explicit operator bool() const noexcept { return ok(); }

    T &value() & {
        check(ok());
        return std::get<0>(storage_);
    }
    const T &value() const & {
        check(ok());
        return std::get<0>(storage_);
    }
    T &&value() && {
        check(ok());
        return std::get<0>(std::move(storage_));
    }
    T *operator->() { return &value(); }
    const T *operator->() const { return &value(); }
    T &operator*() & { return value(); }
    const T &operator*() const & { return value(); }

    const MediaError &error() const & {
        check(!ok());
        return std::get<1>(storage_);
    }
    MediaError &&error() && {
        check(!ok());
        return std::get<1>(std::move(storage_));
    }

  private:
    static void check(bool condition) {
        if (!condition) {
            __builtin_trap();
        }
    }
    std::variant<T, MediaError> storage_;
};

template <> class [[nodiscard]] Result<void> {
  public:
    Result() = default;
    Result(MediaError error) : error_(std::move(error)) {}

    bool ok() const noexcept { return !error_.has_value(); }
    explicit operator bool() const noexcept { return ok(); }

    const MediaError &error() const & {
        if (!error_) {
            __builtin_trap();
        }
        return *error_;
    }
    MediaError &&error() && {
        if (!error_) {
            __builtin_trap();
        }
        return std::move(*error_);
    }

  private:
    std::optional<MediaError> error_;
};

using Status = Result<void>;

inline Status okStatus() {
    return {};
}

} // namespace ve::media

/// Evaluates a Result-returning expression and returns its error from the enclosing function
/// (whose return type must be some Result<U>) if it failed.
#define VE_MEDIA_TRY(expr)                                                                                             \
    do {                                                                                                               \
        auto &&veMediaTryResult_ = (expr);                                                                             \
        if (!veMediaTryResult_.ok()) {                                                                                 \
            return std::move(veMediaTryResult_).error();                                                               \
        }                                                                                                              \
    } while (0)
