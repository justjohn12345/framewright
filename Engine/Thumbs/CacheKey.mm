#include "CacheKey.h"

#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>

namespace ve::thumbs {

using media::MediaErrorCode;
using media::makeError;

FileIdentity fileIdentity(const std::string &path) {
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0) {
        return {};
    }
    return {static_cast<uint64_t>(st.st_size),
            static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000 + st.st_mtimespec.tv_nsec};
}

Hasher &Hasher::add(std::string_view bytes) {
    for (unsigned char c : bytes) {
        h_ ^= c;
        h_ *= 1099511628211ull;
    }
    // Length terminator so ("ab","c") and ("a","bc") differ.
    return add(static_cast<uint64_t>(bytes.size()));
}

Hasher &Hasher::add(uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        h_ ^= (value >> (8 * i)) & 0xff;
        h_ *= 1099511628211ull;
    }
    return *this;
}

std::string Hasher::hex() const {
    char buf[17];
    snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h_));
    return buf;
}

media::Status ensureDirectory(const std::string &directory) {
    if (directory.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "cache directory path is empty");
    }
    std::error_code ec;
    std::filesystem::create_directories(directory, ec);
    if (ec && !std::filesystem::is_directory(directory)) {
        return makeError(ec == std::errc::permission_denied ? MediaErrorCode::PermissionDenied
                                                            : MediaErrorCode::WriteFailed,
                         "cannot create " + directory + ": " + ec.message(), "errno", ec.value());
    }
    return media::okStatus();
}

media::Status writeFileAtomically(const std::string &path, const void *bytes, size_t size) {
    static std::atomic<uint64_t> counter{0};
    const std::string tmp = path + ".tmp-" + std::to_string(::getpid()) + "-" + std::to_string(++counter);
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) {
            return makeError(errno == EACCES ? MediaErrorCode::PermissionDenied : MediaErrorCode::WriteFailed,
                             "cannot create " + tmp + ": " + std::strerror(errno), "errno", errno);
        }
        out.write(static_cast<const char *>(bytes), static_cast<std::streamsize>(size));
        out.close();
        if (!out) {
            std::remove(tmp.c_str());
            return makeError(MediaErrorCode::WriteFailed, "cannot write " + tmp);
        }
    }
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        const int err = errno;
        std::remove(tmp.c_str());
        return makeError(MediaErrorCode::WriteFailed, "cannot rename " + tmp + ": " + std::strerror(err), "errno",
                         err);
    }
    return media::okStatus();
}

// MARK: - DiskCacheBudget

DiskCacheBudget::DiskCacheBudget(std::string directory, std::string extension, uint64_t budgetBytes)
    : directory_(std::move(directory)), extension_(std::move(extension)), budget_(budgetBytes) {}

void DiskCacheBudget::touch(const std::string &path) {
    // Refresh the modification time (the LRU clock). Failure is harmless: the file just ages.
    ::utimes(path.c_str(), nullptr);
}

void DiskCacheBudget::scanLocked() {
    namespace fs = std::filesystem;
    total_ = 0;
    std::error_code ec;
    for (fs::directory_iterator it(directory_, ec), end; !ec && it != end; it.increment(ec)) {
        if (it->path().extension() == extension_ && it->is_regular_file(ec)) {
            total_ += it->file_size(ec);
        }
    }
    scanned_ = true;
}

uint64_t DiskCacheBudget::totalBytes() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!scanned_) {
        scanLocked();
    }
    return total_;
}

void DiskCacheBudget::added(uint64_t bytes) {
    bool over = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!scanned_) {
            scanLocked(); // Includes the file just written.
        } else {
            total_ += bytes;
        }
        over = budget_ > 0 && total_ > budget_;
    }
    if (over) {
        trimTo(budget_ / 10 * 9);
    }
}

int DiskCacheBudget::trimTo(uint64_t targetBytes) {
    namespace fs = std::filesystem;
    struct File {
        fs::path path;
        uint64_t size = 0;
        int64_t modified = 0;
    };
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<File> files;
    uint64_t total = 0;
    std::error_code ec;
    for (fs::directory_iterator it(directory_, ec), end; !ec && it != end; it.increment(ec)) {
        if (it->path().extension() != extension_ || !it->is_regular_file(ec)) {
            continue;
        }
        const FileIdentity id = fileIdentity(it->path().string());
        files.push_back(File{it->path(), id.size, id.modifiedNanoseconds});
        total += id.size;
    }
    std::sort(files.begin(), files.end(), [](const File &a, const File &b) { return a.modified < b.modified; });
    int removed = 0;
    for (const File &f : files) {
        if (total <= targetBytes) {
            break;
        }
        if (fs::remove(f.path, ec)) {
            total -= std::min(total, f.size);
            ++removed;
        }
    }
    total_ = total;
    scanned_ = true;
    return removed;
}

} // namespace ve::thumbs
