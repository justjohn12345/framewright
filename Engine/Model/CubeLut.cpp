#include "CubeLut.h"

#include <cctype>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace ve {

namespace {

std::string_view trimmed(std::string_view s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) {
        s.remove_prefix(1);
    }
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) {
        s.remove_suffix(1);
    }
    return s;
}

// The whitespace-separated words of `s`.
std::vector<std::string_view> words(std::string_view s) {
    std::vector<std::string_view> out;
    std::size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) {
            ++i;
        }
        const std::size_t start = i;
        while (i < s.size() && !std::isspace(static_cast<unsigned char>(s[i]))) {
            ++i;
        }
        if (i > start) {
            out.push_back(s.substr(start, i - start));
        }
    }
    return out;
}

// A number of the text, all of `word` (strtof accepts what the format writes: decimals and exponents).
std::optional<float> numberOf(std::string_view word) {
    if (word.empty() || word.size() > 63) {
        return std::nullopt;
    }
    char buffer[64];
    std::memcpy(buffer, word.data(), word.size());
    buffer[word.size()] = '\0';
    char *end = nullptr;
    const float value = std::strtof(buffer, &end);
    if (end != buffer + word.size()) {
        return std::nullopt;
    }
    return value;
}

std::optional<std::uint32_t> sizeOf(std::string_view word) {
    std::uint32_t value = 0;
    const auto [end, error] = std::from_chars(word.data(), word.data() + word.size(), value);
    if (error != std::errc() || end != word.data() + word.size()) {
        return std::nullopt;
    }
    return value;
}

std::string lineText(std::size_t line) {
    return "line " + std::to_string(line) + ": ";
}

} // namespace

std::size_t CubeLut::entryCount() const {
    return kind == CubeKind::OneD ? std::size_t(size) : std::size_t(size) * size * size;
}

std::array<float, 3> CubeLut::entry(std::uint32_t r, std::uint32_t g, std::uint32_t b) const {
    const std::size_t index = kind == CubeKind::OneD ? r : (std::size_t(b) * size + g) * size + r;
    return {table[index * 3], table[index * 3 + 1], table[index * 3 + 2]};
}

CubeParseResult parseCube(std::string_view text) {
    CubeLut lut;
    std::optional<CubeKind> kind;
    bool dataStarted = false;
    std::size_t lineNumber = 0;
    std::size_t entries = 0;
    auto fail = [](std::string message) { return CubeParseResult{std::nullopt, std::move(message)}; };
    while (!text.empty()) {
        const std::size_t newline = text.find_first_of("\r\n");
        std::string_view line = newline == std::string_view::npos ? text : text.substr(0, newline);
        if (newline == std::string_view::npos) {
            text = std::string_view();
        } else {
            const bool crlf = text[newline] == '\r' && newline + 1 < text.size() && text[newline + 1] == '\n';
            text = text.substr(newline + (crlf ? 2 : 1));
        }
        ++lineNumber;
        if (const std::size_t hash = line.find('#'); hash != std::string_view::npos) {
            line = line.substr(0, hash);
        }
        line = trimmed(line);
        if (line.empty()) {
            continue;
        }
        const std::vector<std::string_view> parts = words(line);
        const bool isData = std::isdigit(static_cast<unsigned char>(parts[0][0])) || parts[0][0] == '-' ||
                            parts[0][0] == '+' || parts[0][0] == '.';
        if (!isData) {
            if (dataStarted) {
                return fail(lineText(lineNumber) + "a keyword after the table's values");
            }
            const std::string_view keyword = parts[0];
            if (keyword == "TITLE") {
                const std::size_t open = line.find('"');
                const std::size_t close = line.rfind('"');
                lut.title = open != std::string_view::npos && close > open ? std::string(line.substr(open + 1, close - open - 1))
                                                                            : std::string(trimmed(line.substr(5)));
            } else if (keyword == "LUT_1D_SIZE" || keyword == "LUT_3D_SIZE") {
                if (kind) {
                    return fail(lineText(lineNumber) + "a second LUT size");
                }
                const auto size = parts.size() == 2 ? sizeOf(parts[1]) : std::nullopt;
                kind = keyword == "LUT_1D_SIZE" ? CubeKind::OneD : CubeKind::ThreeD;
                const std::uint32_t limit = *kind == CubeKind::OneD ? kMaxCube1DSize : kMaxCube3DSize;
                if (!size || *size < 2 || *size > limit) {
                    return fail(lineText(lineNumber) + std::string(keyword) + " must be a whole number from 2 to " +
                                std::to_string(limit));
                }
                lut.size = *size;
            } else if (keyword == "DOMAIN_MIN" || keyword == "DOMAIN_MAX") {
                std::array<float, 3> &target = keyword == "DOMAIN_MIN" ? lut.domainMin : lut.domainMax;
                if (parts.size() != 4) {
                    return fail(lineText(lineNumber) + std::string(keyword) + " needs three numbers");
                }
                for (int c = 0; c < 3; ++c) {
                    const auto value = numberOf(parts[std::size_t(c) + 1]);
                    if (!value || !std::isfinite(*value)) {
                        return fail(lineText(lineNumber) + std::string(keyword) + " needs three numbers");
                    }
                    target[std::size_t(c)] = *value;
                }
            } else if (keyword == "LUT_1D_INPUT_RANGE" || keyword == "LUT_3D_INPUT_RANGE") {
                const auto low = parts.size() == 3 ? numberOf(parts[1]) : std::nullopt;
                const auto high = parts.size() == 3 ? numberOf(parts[2]) : std::nullopt;
                if (!low || !high || !std::isfinite(*low) || !std::isfinite(*high)) {
                    return fail(lineText(lineNumber) + std::string(keyword) + " needs two numbers");
                }
                lut.domainMin = {*low, *low, *low};
                lut.domainMax = {*high, *high, *high};
            }
            // Other keywords (a vendor's) are ignored.
            continue;
        }
        if (!kind) {
            return fail(lineText(lineNumber) + "a value before LUT_1D_SIZE or LUT_3D_SIZE");
        }
        dataStarted = true;
        if (parts.size() != 3) {
            return fail(lineText(lineNumber) + "a table line needs three numbers");
        }
        if (entries == (*kind == CubeKind::OneD ? std::size_t(lut.size) : std::size_t(lut.size) * lut.size * lut.size)) {
            return fail(lineText(lineNumber) + "more values than the LUT's size");
        }
        for (const std::string_view part : parts) {
            const auto value = numberOf(part);
            if (!value) {
                return fail(lineText(lineNumber) + "\"" + std::string(part) + "\" is not a number");
            }
            if (!std::isfinite(*value)) {
                return fail(lineText(lineNumber) + "a value that is not finite");
            }
            lut.table.push_back(*value);
        }
        ++entries;
    }
    if (!kind) {
        return fail("not a .cube LUT: no LUT_1D_SIZE or LUT_3D_SIZE");
    }
    lut.kind = *kind;
    if (entries != lut.entryCount()) {
        return fail("the table has " + std::to_string(entries) + " values; LUT_" +
                    std::string(*kind == CubeKind::OneD ? "1D" : "3D") + "_SIZE " + std::to_string(lut.size) + " needs " +
                    std::to_string(lut.entryCount()));
    }
    if (auto problem = cubeProblem(lut)) {
        return fail(*problem);
    }
    return CubeParseResult{std::move(lut), {}};
}

std::optional<std::string> cubeProblem(const CubeLut &lut) {
    const std::uint32_t limit = lut.kind == CubeKind::OneD ? kMaxCube1DSize : kMaxCube3DSize;
    if (lut.size < 2 || lut.size > limit) {
        return "the LUT's size " + std::to_string(lut.size) + " is not from 2 to " + std::to_string(limit);
    }
    if (lut.table.size() != lut.entryCount() * 3) {
        return "the LUT's table has " + std::to_string(lut.table.size() / 3) + " entries, not " +
               std::to_string(lut.entryCount());
    }
    for (const float value : lut.table) {
        if (!std::isfinite(value)) {
            return std::string("the LUT's table has a value that is not finite");
        }
    }
    for (int c = 0; c < 3; ++c) {
        if (!std::isfinite(lut.domainMin[std::size_t(c)]) || !std::isfinite(lut.domainMax[std::size_t(c)]) ||
            !(lut.domainMin[std::size_t(c)] < lut.domainMax[std::size_t(c)])) {
            return std::string("the LUT's domain minimum must be below its maximum");
        }
    }
    return std::nullopt;
}

std::string cubeContentId(const CubeLut &lut) {
    std::uint64_t hash = 14695981039346656037ull;
    auto add = [&hash](const void *data, std::size_t length) {
        const auto *bytes = static_cast<const unsigned char *>(data);
        for (std::size_t i = 0; i < length; ++i) {
            hash ^= bytes[i];
            hash *= 1099511628211ull;
        }
    };
    const std::uint32_t kind = lut.kind == CubeKind::OneD ? 1u : 3u;
    add(&kind, sizeof kind);
    add(&lut.size, sizeof lut.size);
    add(lut.domainMin.data(), sizeof(float) * 3);
    add(lut.domainMax.data(), sizeof(float) * 3);
    add(lut.table.data(), lut.table.size() * sizeof(float));
    char text[17];
    std::snprintf(text, sizeof text, "%016llx", static_cast<unsigned long long>(hash));
    return text;
}

} // namespace ve
