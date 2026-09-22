#include "CacheKey.h"

#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>

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

} // namespace ve::thumbs
