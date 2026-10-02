// A colour look-up table read from a .cube file (Adobe's Cube LUT format 1.0, with the input-range keywords
// Resolve writes), for a clip's grade (ClipGrade.h: an input conversion before the grade, or a look after it).
// The project keeps a copy of the table (Project::luts, by its content id), so a project opens wherever it
// goes; the file's name and path are kept to show where it came from.
//
// Reading: '#' comments and blank lines are skipped; TITLE "..."; LUT_1D_SIZE N (2 to kMaxCube1DSize) or
// LUT_3D_SIZE N (2 to kMaxCube3DSize), exactly one; DOMAIN_MIN r g b and DOMAIN_MAX r g b (each min below its
// max; default 0 and 1); LUT_1D_INPUT_RANGE / LUT_3D_INPUT_RANGE min max (the same range for every channel);
// other keywords before the data are ignored (vendors add their own). Then exactly N (1D) or N^3 (3D) lines of
// three finite numbers, red changing fastest. Anything else is refused with a message saying what and where.
//
// Plain C++: unit-testable without Metal or media.

#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ve {

enum class CubeKind {
    OneD,
    ThreeD,
};

inline constexpr std::uint32_t kMaxCube1DSize = 65536;
inline constexpr std::uint32_t kMaxCube3DSize = 129;

struct CubeLut {
    CubeKind kind = CubeKind::ThreeD;
    std::uint32_t size = 0;
    std::array<float, 3> domainMin{0.0f, 0.0f, 0.0f};
    std::array<float, 3> domainMax{1.0f, 1.0f, 1.0f};
    // RGB triples: `size` entries (1D) or size^3 (3D, red fastest, then green, then blue).
    std::vector<float> table;
    // Where it came from: the file's TITLE (or "") and its name and path when imported (for display).
    std::string title;
    std::string fileName;
    std::string sourcePath;

    // The number of RGB entries the table holds for its kind and size.
    std::size_t entryCount() const;
    // The entry at (r, g, b) of a 3D table (or at r of a 1D one, g and b ignored).
    std::array<float, 3> entry(std::uint32_t r, std::uint32_t g = 0, std::uint32_t b = 0) const;

    friend bool operator==(const CubeLut &, const CubeLut &) = default;
};

struct CubeParseResult {
    std::optional<CubeLut> lut;
    std::string error; // why the text is not a LUT this version reads ("line 12: ...")
};

// Reads the text of a .cube file.
CubeParseResult parseCube(std::string_view text);

// Why `lut` is not a valid LUT (a size out of range, a table of the wrong length or with a value that is not
// finite, a domain whose min is not below its max), or nullopt.
std::optional<std::string> cubeProblem(const CubeLut &lut);

// The LUT's content id: 16 hex digits of a 64-bit FNV-1a hash of its kind, size, domain and table (not its
// names), so the same table imported twice is stored once.
std::string cubeContentId(const CubeLut &lut);

} // namespace ve
