// Reading .cube LUTs (CubeLut.h): a generated identity 3D and 1D file, the keywords (TITLE, DOMAIN_MIN/MAX, the
// input-range keywords, a vendor's keyword ignored), comments, blank lines and CRLF line ends; every malformed
// file refused with a message naming what and where (no size, two sizes, a size out of range, too few or too
// many values, a value that is not a number or not finite, a line with two numbers, a keyword after the
// values, a domain whose minimum is not below its maximum); the content id (the same table gives the same id
// whatever its names, a different table another).

#include "../../Engine/Model/CubeLut.h"

#include <doctest.h>

#include <cmath>
#include <cstdio>
#include <string>

using namespace ve;

namespace {

// The text of an identity 3D LUT of `size` per side (red fastest), with an optional header.
std::string identity3D(int size, const std::string &header = "") {
    std::string text = header + "LUT_3D_SIZE " + std::to_string(size) + "\n";
    char line[96];
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                std::snprintf(line, sizeof line, "%.6f %.6f %.6f\n", r / double(size - 1), g / double(size - 1),
                              b / double(size - 1));
                text += line;
            }
        }
    }
    return text;
}

std::string errorOf(const std::string &text) {
    const CubeParseResult parsed = parseCube(text);
    CHECK_FALSE(parsed.lut.has_value());
    return parsed.error;
}

} // namespace

TEST_CASE("Cube LUTs: a generated identity 3D LUT") {
    const CubeParseResult parsed = parseCube(identity3D(17, "# made by a test\nTITLE \"Identity 17\"\n\n"));
    REQUIRE_MESSAGE(parsed.lut.has_value(), doctest::String(parsed.error.c_str()));
    const CubeLut &lut = *parsed.lut;
    CHECK(lut.kind == CubeKind::ThreeD);
    CHECK(lut.size == 17);
    CHECK(lut.title == "Identity 17");
    CHECK(lut.entryCount() == 17u * 17u * 17u);
    CHECK(lut.table.size() == lut.entryCount() * 3);
    CHECK(lut.domainMin == std::array<float, 3>{0, 0, 0});
    CHECK(lut.domainMax == std::array<float, 3>{1, 1, 1});
    // Red fastest: entry (r, g, b) is (r, g, b) / 16.
    const auto e = lut.entry(4, 8, 16);
    CHECK(e[0] == doctest::Approx(0.25));
    CHECK(e[1] == doctest::Approx(0.5));
    CHECK(e[2] == doctest::Approx(1.0));
    CHECK_FALSE(cubeProblem(lut).has_value());
}

TEST_CASE("Cube LUTs: a 1D LUT, domains, input ranges, vendor keywords and line ends") {
    const CubeParseResult one = parseCube("TITLE \"Shaper\"\r\nLUT_1D_SIZE 3\r\nDOMAIN_MIN -0.5 0 0\r\n"
                                          "DOMAIN_MAX 1.5 1 2\r\nLUT_IN_VIDEO_RANGE\r\n0 0 0\r\n0.5 0.25 0.75 # mid\r\n"
                                          "1 1 1\r\n");
    REQUIRE_MESSAGE(one.lut.has_value(), doctest::String(one.error.c_str()));
    CHECK(one.lut->kind == CubeKind::OneD);
    CHECK(one.lut->size == 3);
    CHECK(one.lut->domainMin == std::array<float, 3>{-0.5f, 0.0f, 0.0f});
    CHECK(one.lut->domainMax == std::array<float, 3>{1.5f, 1.0f, 2.0f});
    CHECK(one.lut->entry(1) == std::array<float, 3>{0.5f, 0.25f, 0.75f});
    const CubeParseResult ranged = parseCube("LUT_3D_INPUT_RANGE -0.25 1.25\nLUT_3D_SIZE 2\n" "0 0 0\n1 0 0\n0 1 0\n1 1 0\n"
                                             "0 0 1\n1 0 1\n0 1 1\n1 1 1");
    REQUIRE_MESSAGE(ranged.lut.has_value(), doctest::String(ranged.error.c_str()));
    CHECK(ranged.lut->domainMin == std::array<float, 3>{-0.25f, -0.25f, -0.25f});
    CHECK(ranged.lut->domainMax == std::array<float, 3>{1.25f, 1.25f, 1.25f});
    // Values beyond [0, 1] are kept (a LUT may produce them); exponents are read.
    const CubeParseResult wide = parseCube("LUT_1D_SIZE 2\n-1e-1 0 0\n1.5E0 1 1\n");
    REQUIRE(wide.lut.has_value());
    CHECK(wide.lut->entry(0)[0] == doctest::Approx(-0.1));
    CHECK(wide.lut->entry(1)[0] == doctest::Approx(1.5));
}

TEST_CASE("Cube LUTs: malformed files are refused with what and where") {
    CHECK(errorOf("# nothing\n") == "not a .cube LUT: no LUT_1D_SIZE or LUT_3D_SIZE");
    CHECK(errorOf("0 0 0\n") == "line 1: a value before LUT_1D_SIZE or LUT_3D_SIZE");
    CHECK(errorOf("LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n") == "line 2: a second LUT size");
    CHECK(errorOf("LUT_3D_SIZE 1\n") == "line 1: LUT_3D_SIZE must be a whole number from 2 to 129");
    CHECK(errorOf("LUT_3D_SIZE 130\n") == "line 1: LUT_3D_SIZE must be a whole number from 2 to 129");
    CHECK(errorOf("LUT_1D_SIZE 65537\n") == "line 1: LUT_1D_SIZE must be a whole number from 2 to 65536");
    CHECK(errorOf("LUT_1D_SIZE two\n") == "line 1: LUT_1D_SIZE must be a whole number from 2 to 65536");
    CHECK(errorOf("LUT_1D_SIZE 3\n0 0 0\n1 1 1\n") == "the table has 2 values; LUT_1D_SIZE 3 needs 3");
    CHECK(errorOf("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n1 1 1\n") == "line 4: more values than the LUT's size");
    CHECK(errorOf("LUT_1D_SIZE 2\n0 0 0\n1 x 1\n") == "line 3: \"x\" is not a number");
    CHECK(errorOf("LUT_1D_SIZE 2\n0 0 0\n1 1\n") == "line 3: a table line needs three numbers");
    CHECK(errorOf("LUT_1D_SIZE 2\n0 0 0\n1 inf 1\n") == "line 3: a value that is not finite");
    CHECK(errorOf("LUT_1D_SIZE 2\n0 0 0\nTITLE \"late\"\n1 1 1\n") == "line 3: a keyword after the table's values");
    CHECK(errorOf("DOMAIN_MIN 0 0\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n") == "line 1: DOMAIN_MIN needs three numbers");
    CHECK(errorOf("DOMAIN_MIN 0 0 1\nDOMAIN_MAX 1 1 1\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n") ==
          "the LUT's domain minimum must be below its maximum");
    CHECK(errorOf("LUT_3D_INPUT_RANGE 0\nLUT_3D_SIZE 2\n") == "line 1: LUT_3D_INPUT_RANGE needs two numbers");
}

TEST_CASE("Cube LUTs: the content id") {
    CubeLut a = *parseCube(identity3D(5)).lut;
    CubeLut b = a;
    b.title = "Another name";
    b.fileName = "other.cube";
    b.sourcePath = "/elsewhere/other.cube";
    CHECK(cubeContentId(a) == cubeContentId(b));
    CHECK(cubeContentId(a).size() == 16);
    b.table[7] += 0.001f;
    CHECK(cubeContentId(a) != cubeContentId(b));
    CubeLut c = a;
    c.domainMax[2] = 2.0f;
    CHECK(cubeContentId(a) != cubeContentId(c));
    // A problem found without parsing: a table of the wrong length, a value that is not finite.
    CubeLut bad = a;
    bad.table.pop_back();
    CHECK(cubeProblem(bad).has_value());
    bad = a;
    bad.table[0] = std::nanf("");
    CHECK(cubeProblem(bad).has_value());
}
