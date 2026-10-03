#include "TestFont.h"

#include <cstdint>
#include <fstream>
#include <map>
#include <vector>

namespace ve::test {

namespace {

using Bytes = std::vector<std::uint8_t>;

void u16(Bytes &out, std::uint32_t value) {
    out.push_back(std::uint8_t(value >> 8));
    out.push_back(std::uint8_t(value));
}

void i16(Bytes &out, std::int32_t value) {
    u16(out, std::uint32_t(std::uint16_t(std::int16_t(value))));
}

void u32(Bytes &out, std::uint32_t value) {
    u16(out, value >> 16);
    u16(out, value & 0xFFFF);
}

void zeros(Bytes &out, std::size_t count) {
    out.insert(out.end(), count, 0);
}

std::uint32_t checksum(const Bytes &data) {
    std::uint32_t sum = 0;
    for (std::size_t i = 0; i < data.size(); i += 4) {
        std::uint32_t word = 0;
        for (std::size_t j = 0; j < 4; ++j) {
            word = (word << 8) | (i + j < data.size() ? data[i + j] : 0);
        }
        sum += word;
    }
    return sum;
}

// Glyphs: 0 .notdef (empty), 1 the space (empty), 2 ... 95 the box (characters 0x21 to 0x7E).
constexpr std::uint32_t kGlyphs = 96;
constexpr std::int32_t kUnitsPerEm = 1000;
constexpr std::int32_t kAscender = 800;
constexpr std::int32_t kDescender = -200;
constexpr std::int32_t kAdvance = 600;

Bytes boxGlyph() {
    Bytes g;
    i16(g, 1);   // one contour
    i16(g, 50);  // xMin
    i16(g, 0);   // yMin
    i16(g, 550); // xMax
    i16(g, 700); // yMax
    u16(g, 3);   // the contour's last point
    u16(g, 0);   // no instructions
    for (int i = 0; i < 4; ++i) {
        g.push_back(0x01); // on the curve, x and y as 16-bit deltas
    }
    // (50, 0) -> (50, 700) -> (550, 700) -> (550, 0): clockwise, an outer contour.
    for (std::int32_t dx : {50, 0, 500, 0}) {
        i16(g, dx);
    }
    for (std::int32_t dy : {0, 700, 0, -700}) {
        i16(g, dy);
    }
    while (g.size() % 4 != 0) {
        g.push_back(0);
    }
    return g;
}

Bytes utf16(const std::string &ascii) {
    Bytes out;
    for (char c : ascii) {
        u16(out, std::uint8_t(c));
    }
    return out;
}

} // namespace

std::string writeBoxFont(const std::string &path, const std::string &family, const std::string &postScriptName) {
    std::map<std::string, Bytes> tables;

    Bytes &head = tables["head"];
    u32(head, 0x00010000); // version
    u32(head, 0x00010000); // font revision
    u32(head, 0);          // checksum adjustment (set below)
    u32(head, 0x5F0F3CF5); // magic
    u16(head, 0x000B);     // flags: baseline at 0, left side bearing at 0, integer scaling
    u16(head, kUnitsPerEm);
    zeros(head, 16); // created, modified
    i16(head, 0);
    i16(head, kDescender);
    i16(head, kAdvance);
    i16(head, kAscender);
    u16(head, 0); // macStyle
    u16(head, 8); // lowest readable size
    i16(head, 2); // font direction hint
    i16(head, 1); // long loca offsets
    i16(head, 0); // glyph data format

    Bytes &hhea = tables["hhea"];
    u32(hhea, 0x00010000);
    i16(hhea, kAscender);
    i16(hhea, kDescender);
    i16(hhea, 0); // line gap
    u16(hhea, kAdvance);
    i16(hhea, 0);   // min left side bearing
    i16(hhea, 0);   // min right side bearing
    i16(hhea, 550); // x max extent
    i16(hhea, 1);   // caret slope rise
    i16(hhea, 0);   // caret slope run
    i16(hhea, 0);   // caret offset
    zeros(hhea, 8); // reserved
    i16(hhea, 0);   // metric data format
    u16(hhea, kGlyphs);

    Bytes &maxp = tables["maxp"];
    u32(maxp, 0x00010000);
    u16(maxp, kGlyphs);
    u16(maxp, 4); // max points
    u16(maxp, 1); // max contours
    u16(maxp, 0);
    u16(maxp, 0);
    u16(maxp, 2); // max zones
    zeros(maxp, 16);

    Bytes &os2 = tables["OS/2"];
    u16(os2, 4); // version
    i16(os2, kAdvance);
    u16(os2, 400); // weight: regular
    u16(os2, 5);   // width: normal
    u16(os2, 0);   // embedding: installable
    for (std::int32_t v : {650, 600, 0, 75, 650, 600, 0, 350, 50, 250}) {
        i16(os2, v); // sub- and superscript sizes and offsets, strikeout size and position
    }
    i16(os2, 0);    // family class
    zeros(os2, 10); // panose
    u32(os2, 1);    // Unicode ranges: Basic Latin
    zeros(os2, 12);
    os2.insert(os2.end(), {'F', 'W', 'T', 'S'}); // vendor
    u16(os2, 0x0040);                            // fsSelection: regular
    u16(os2, 0x20);                              // first character
    u16(os2, 0x7E);                              // last character
    i16(os2, kAscender);
    i16(os2, kDescender);
    i16(os2, 0); // typographic line gap
    u16(os2, kAscender);
    u16(os2, -kDescender);
    u32(os2, 1); // code pages: Latin 1
    u32(os2, 0);
    i16(os2, 500); // x height
    i16(os2, 700); // cap height
    u16(os2, 0);   // default character
    u16(os2, 0x20);
    u16(os2, 1); // max context

    Bytes &hmtx = tables["hmtx"];
    for (std::uint32_t glyph = 0; glyph < kGlyphs; ++glyph) {
        u16(hmtx, kAdvance);
        i16(hmtx, glyph >= 2 ? 50 : 0);
    }

    Bytes &cmap = tables["cmap"];
    u16(cmap, 0); // version
    u16(cmap, 1); // one encoding
    u16(cmap, 3); // Windows
    u16(cmap, 1); // Unicode BMP
    u32(cmap, 12);
    // Format 4: 0x20...0x7E -> glyphs 1...95 (idDelta), and the closing 0xFFFF segment.
    u16(cmap, 4);
    u16(cmap, 32); // length: 14 + 2 segments x 8 + 2
    u16(cmap, 0);  // language
    u16(cmap, 4);  // segCountX2
    u16(cmap, 4);  // searchRange
    u16(cmap, 1);  // entrySelector
    u16(cmap, 0);  // rangeShift
    u16(cmap, 0x7E);
    u16(cmap, 0xFFFF); // end codes
    u16(cmap, 0);      // reserved
    u16(cmap, 0x20);
    u16(cmap, 0xFFFF);                   // start codes
    u16(cmap, std::uint16_t(1 - 0x20)); // deltas
    u16(cmap, 1);
    u16(cmap, 0);
    u16(cmap, 0); // range offsets

    Bytes &glyf = tables["glyf"];
    Bytes &loca = tables["loca"];
    const Bytes box = boxGlyph();
    for (std::uint32_t glyph = 0; glyph < kGlyphs; ++glyph) {
        u32(loca, std::uint32_t(glyf.size()));
        if (glyph >= 2) {
            glyf.insert(glyf.end(), box.begin(), box.end());
        }
    }
    u32(loca, std::uint32_t(glyf.size()));

    Bytes &name = tables["name"];
    const std::vector<std::pair<std::uint16_t, Bytes>> names = {
        {1, utf16(family)},           {2, utf16("Regular")}, {3, utf16(postScriptName + " test")},
        {4, utf16(family + " Regular")}, {6, utf16(postScriptName)},
    };
    u16(name, 0);
    u16(name, std::uint16_t(names.size()));
    u16(name, std::uint16_t(6 + 12 * names.size()));
    std::uint16_t offset = 0;
    for (const auto &[id, text] : names) {
        u16(name, 3);      // Windows
        u16(name, 1);      // Unicode BMP
        u16(name, 0x0409); // English (United States)
        u16(name, id);
        u16(name, std::uint16_t(text.size()));
        u16(name, offset);
        offset = std::uint16_t(offset + text.size());
    }
    for (const auto &[id, text] : names) {
        name.insert(name.end(), text.begin(), text.end());
    }

    Bytes &post = tables["post"];
    u32(post, 0x00030000); // no glyph names
    u32(post, 0);          // italic angle
    i16(post, -100);       // underline position
    i16(post, 50);         // underline thickness
    zeros(post, 20);

    // The file: the table directory (tags in order, as std::map keeps them), then each table on 4 bytes.
    const std::uint16_t count = std::uint16_t(tables.size());
    std::uint16_t power = 1;
    std::uint16_t selector = 0;
    while (power * 2 <= count) {
        power = std::uint16_t(power * 2);
        ++selector;
    }
    Bytes file;
    u32(file, 0x00010000);
    u16(file, count);
    u16(file, std::uint16_t(power * 16));
    u16(file, selector);
    u16(file, std::uint16_t(count * 16 - power * 16));
    std::uint32_t at = 12 + 16 * count;
    std::size_t headOffset = 0;
    for (auto &[tag, data] : tables) {
        file.insert(file.end(), tag.begin(), tag.end());
        u32(file, checksum(data));
        u32(file, at);
        u32(file, std::uint32_t(data.size()));
        if (tag == "head") {
            headOffset = at;
        }
        at += std::uint32_t((data.size() + 3) / 4 * 4);
    }
    for (auto &[tag, data] : tables) {
        file.insert(file.end(), data.begin(), data.end());
        while (file.size() % 4 != 0) {
            file.push_back(0);
        }
    }
    const std::uint32_t adjustment = 0xB1B0AFBA - checksum(file);
    for (int i = 0; i < 4; ++i) {
        file[headOffset + 8 + i] = std::uint8_t(adjustment >> (24 - 8 * i));
    }

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        return "cannot write " + path;
    }
    out.write(reinterpret_cast<const char *>(file.data()), std::streamsize(file.size()));
    return out ? "" : "cannot write " + path;
}

} // namespace ve::test
