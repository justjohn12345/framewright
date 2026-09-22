// Helpers shared by the thumbnail and waveform disk caches: a stable content hash and the
// identity of a source file (so an edited or replaced file never hits a stale cache entry).
#pragma once

#include "../Media/Result.h"

#include <cstdint>
#include <string>
#include <string_view>

namespace ve::thumbs {

/// Size and modification time of a file; both 0 if it cannot be stat'ed.
struct FileIdentity {
    uint64_t size = 0;
    int64_t modifiedNanoseconds = 0;
    bool operator==(const FileIdentity &) const = default;
};
FileIdentity fileIdentity(const std::string &path);

/// Incremental 64-bit FNV-1a (stable across runs and platforms; not cryptographic).
class Hasher {
  public:
    Hasher &add(std::string_view bytes);
    Hasher &add(uint64_t value);
    Hasher &add(int64_t value) { return add(static_cast<uint64_t>(value)); }
    uint64_t value() const { return h_; }
    /// 16 lowercase hex digits.
    std::string hex() const;

  private:
    uint64_t h_ = 1469598103934665603ull;
};

/// Creates `directory` (and parents) if needed. InvalidArgument for an empty path,
/// PermissionDenied / WriteFailed if it cannot be created.
media::Status ensureDirectory(const std::string &directory);

/// Writes `bytes` to `path` atomically (temporary file in the same directory, then rename).
media::Status writeFileAtomically(const std::string &path, const void *bytes, size_t size);

} // namespace ve::thumbs
