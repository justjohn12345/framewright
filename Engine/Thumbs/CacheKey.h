// Helpers shared by the thumbnail and waveform disk caches: a stable content hash and the
// identity of a source file (so an edited or replaced file never hits a stale cache entry).
#pragma once

#include "../Media/Result.h"

#include <cstdint>
#include <mutex>
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

/// Size bound for a directory of cache files with one extension (".png", ".vewf"), evicting the
/// least recently used: hits refresh a file's modification time (touch), and when a write takes
/// the total over the budget the oldest files are deleted until it is back under 90 % of it (so
/// eviction does not run on every write). The total is learned by scanning the directory once,
/// lazily, then maintained incrementally; files written by other processes are picked up at the
/// next trim scan. Thread-safe. A budget of 0 means unbounded.
class DiskCacheBudget {
  public:
    DiskCacheBudget(std::string directory, std::string extension, uint64_t budgetBytes);

    /// A cache hit: marks `path` most recently used.
    void touch(const std::string &path);
    /// `bytes` were written to a cache file; trims if the budget is exceeded.
    void added(uint64_t bytes);
    /// Scans the directory and deletes least recently used files until the total is at most
    /// `targetBytes`. Returns the number of files deleted.
    int trimTo(uint64_t targetBytes);
    /// Current total (after the first scan; scans if needed).
    uint64_t totalBytes();

  private:
    void scanLocked();

    const std::string directory_;
    const std::string extension_;
    const uint64_t budget_;
    std::mutex mutex_;
    bool scanned_ = false;
    uint64_t total_ = 0;
};

} // namespace ve::thumbs
