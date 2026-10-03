#include "GeneratedContent.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <iterator>

namespace ve {

namespace {

using T = TitleValueType;
using U = TitleUnit;

constexpr TitleParameterInfo kTitleTable[] = {
    {TitleParameter::Text, "text", "Text", T::Text, U::None, 0, 0, 0, true},
    {TitleParameter::Font, "font", "Font", T::Font, U::None, 0, 0, 0, true},
    {TitleParameter::Size, "size", "Size", T::Number, U::FrameHeight, 0.06, 0.005, 1.0, true},
    {TitleParameter::FillColour, "fillColour", "Fill Colour", T::Colour, U::None, 0, 0, 0, true},
    {TitleParameter::Alignment, "alignment", "Alignment", T::Choice, U::None, 0, 0, 0, true},
    {TitleParameter::LineSpacing, "lineSpacing", "Line Spacing", T::Number, U::Multiple, 1.0, 0.5, 3.0, true},
    {TitleParameter::Tracking, "tracking", "Tracking", T::Number, U::ThousandthsEm, 0.0, -200.0, 1000.0, true},
    {TitleParameter::Outline, "outline", "Outline", T::Toggle, U::None, 0, 0, 1, true},
    {TitleParameter::OutlineColour, "outlineColour", "Outline Colour", T::Colour, U::None, 0, 0, 0, true},
    {TitleParameter::OutlineWidth, "outlineWidth", "Outline Width", T::Number, U::FrameHeight, 0.003, 0.0, 0.05, true},
    {TitleParameter::Shadow, "shadow", "Shadow", T::Toggle, U::None, 1, 0, 1, true},
    {TitleParameter::ShadowColour, "shadowColour", "Shadow Colour", T::Colour, U::None, 0, 0, 0, true},
    {TitleParameter::ShadowOpacity, "shadowOpacity", "Shadow Opacity", T::Number, U::Fraction, 0.5, 0.0, 1.0, true},
    {TitleParameter::ShadowAngle, "shadowAngle", "Shadow Angle", T::Number, U::Degrees, 135.0, 0.0, 360.0, true},
    {TitleParameter::ShadowDistance, "shadowDistance", "Shadow Distance", T::Number, U::FrameHeight, 0.003, 0.0, 0.1,
     true},
    {TitleParameter::ShadowBlur, "shadowBlur", "Shadow Blur", T::Number, U::FrameHeight, 0.004, 0.0, 0.1, true},
    {TitleParameter::Box, "box", "Background Box", T::Toggle, U::None, 0, 0, 1, true},
    {TitleParameter::BoxColour, "boxColour", "Box Colour", T::Colour, U::None, 0, 0, 0, true},
    {TitleParameter::BoxOpacity, "boxOpacity", "Box Opacity", T::Number, U::Fraction, 0.6, 0.0, 1.0, true},
    {TitleParameter::BoxPadding, "boxPadding", "Box Padding", T::Number, U::FrameHeight, 0.015, 0.0, 0.2, true},
    {TitleParameter::BoxCornerRadius, "boxCornerRadius", "Corner Radius", T::Number, U::FrameHeight, 0.0, 0.0, 0.1,
     true},
    {TitleParameter::PositionX, "x", "Position X", T::Number, U::FrameWidth, 0.5, -1.0, 2.0, false},
    {TitleParameter::PositionY, "y", "Position Y", T::Number, U::FrameHeight, 0.5, -1.0, 2.0, false},
    {TitleParameter::BoxWidth, "width", "Box Width", T::Number, U::FrameWidth, 0.8, 0.02, 4.0, true},
};

// Row i describes enumerator i, kTitleParameters lists them in order, a number's default lies within its
// finite range, and only the position leaves the pixels alone.
constexpr bool titleTableInOrder() {
    std::size_t i = 0;
    for (const TitleParameterInfo &row : kTitleTable) {
        if (static_cast<std::size_t>(row.parameter) != i || kTitleParameters[i] != row.parameter) {
            return false;
        }
        if (row.type == TitleValueType::Number &&
            !(row.minimum < row.maximum && row.minimum <= row.defaultValue && row.defaultValue <= row.maximum &&
              row.minimum > -1e6 && row.maximum < 1e6)) {
            return false;
        }
        const bool position = row.parameter == TitleParameter::PositionX || row.parameter == TitleParameter::PositionY;
        if (row.changesPixels == position) {
            return false;
        }
        ++i;
    }
    return i == kTitleParameterCount;
}
static_assert(titleTableInOrder(), "kTitleTable must describe TitleParameter in order, defaults within finite ranges");
static_assert(std::size(kTitleTable) == kTitleParameterCount);

std::string numberText(double value) {
    char text[32];
    std::snprintf(text, sizeof text, "%g", value);
    return text;
}

// Whether `text` is well-formed UTF-8 (no overlong forms, no surrogates, nothing above U+10FFFF).
bool isUTF8(std::string_view text) {
    std::size_t i = 0;
    while (i < text.size()) {
        const auto c = static_cast<unsigned char>(text[i]);
        std::size_t length = 0;
        std::uint32_t code = 0;
        if (c < 0x80) {
            ++i;
            continue;
        }
        if ((c & 0xE0) == 0xC0) {
            length = 2;
            code = c & 0x1F;
        } else if ((c & 0xF0) == 0xE0) {
            length = 3;
            code = c & 0x0F;
        } else if ((c & 0xF8) == 0xF0) {
            length = 4;
            code = c & 0x07;
        } else {
            return false;
        }
        if (i + length > text.size()) {
            return false;
        }
        for (std::size_t k = 1; k < length; ++k) {
            const auto next = static_cast<unsigned char>(text[i + k]);
            if ((next & 0xC0) != 0x80) {
                return false;
            }
            code = (code << 6) | (next & 0x3F);
        }
        const std::uint32_t smallest = length == 2 ? 0x80 : length == 3 ? 0x800 : 0x10000;
        if (code < smallest || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
            return false;
        }
        i += length;
    }
    return true;
}

// FNV-1a over 128 bits (the standard offset basis and prime, 2^88 + 2^8 + 0x3b).
class Fnv128 {
  public:
    void bytes(const void *data, std::size_t length) {
        const auto *p = static_cast<const unsigned char *>(data);
        for (std::size_t i = 0; i < length; ++i) {
            hash_ ^= p[i];
            hash_ *= kPrime;
        }
    }
    void text(std::string_view s) {
        const std::uint64_t length = s.size();
        bytes(&length, sizeof length);
        bytes(s.data(), s.size());
    }
    void number(double v) {
        if (v == 0.0) {
            v = 0.0; // -0 and +0 draw alike
        }
        std::uint64_t bits = 0;
        std::memcpy(&bits, &v, sizeof bits);
        bytes(&bits, sizeof bits);
    }
    void flag(bool b) {
        const unsigned char byte = b ? 1 : 0;
        bytes(&byte, 1);
    }
    void colour(const SRGBColour &c) {
        number(c.red);
        number(c.green);
        number(c.blue);
    }
    ContentId id() const {
        return ContentId{static_cast<std::uint64_t>(hash_ >> 64), static_cast<std::uint64_t>(hash_)};
    }

  private:
    static constexpr unsigned __int128 kPrime = (static_cast<unsigned __int128>(1) << 88) + 0x13B;
    unsigned __int128 hash_ = (static_cast<unsigned __int128>(0x6c62272e07bb0142ull) << 64) | 0x62b821756295c58dull;
};

constexpr std::array<const char *, 9> kWeightNames{"ultraLight", "thin",     "light", "regular", "medium",
                                                   "semibold",   "bold",     "heavy", "black"};
constexpr std::array<const char *, 9> kWeightDisplayNames{"Ultralight", "Thin",  "Light", "Regular", "Medium",
                                                          "Semibold",   "Bold",  "Heavy", "Black"};

} // namespace

const char *nameOf(GeneratorKind kind) {
    switch (kind) {
    case GeneratorKind::None:
        return "none";
    case GeneratorKind::Title:
        return "title";
    case GeneratorKind::ColourMatte:
        return "colourMatte";
    }
    return "none";
}

const char *displayNameOf(GeneratorKind kind) {
    switch (kind) {
    case GeneratorKind::None:
        return "Media";
    case GeneratorKind::Title:
        return "Title";
    case GeneratorKind::ColourMatte:
        return "Colour Matte";
    }
    return "Media";
}

std::optional<GeneratorKind> generatorKindNamed(std::string_view name) {
    for (const GeneratorKind kind : {GeneratorKind::None, GeneratorKind::Title, GeneratorKind::ColourMatte}) {
        if (name == nameOf(kind)) {
            return kind;
        }
    }
    return std::nullopt;
}

bool isValidColour(const SRGBColour &colour) {
    for (const double c : {colour.red, colour.green, colour.blue}) {
        if (!std::isfinite(c) || c < 0.0 || c > 1.0) {
            return false;
        }
    }
    return true;
}

const char *nameOf(TitleAlignment alignment) {
    switch (alignment) {
    case TitleAlignment::Left:
        return "left";
    case TitleAlignment::Centre:
        return "centre";
    case TitleAlignment::Right:
        return "right";
    }
    return "centre";
}

std::optional<TitleAlignment> titleAlignmentNamed(std::string_view name) {
    for (const TitleAlignment alignment : {TitleAlignment::Left, TitleAlignment::Centre, TitleAlignment::Right}) {
        if (name == nameOf(alignment)) {
            return alignment;
        }
    }
    return std::nullopt;
}

const char *nameOf(SystemFontWeight weight) {
    const auto i = static_cast<std::size_t>(weight);
    return i < kWeightNames.size() ? kWeightNames[i] : "regular";
}

const char *displayNameOf(SystemFontWeight weight) {
    const auto i = static_cast<std::size_t>(weight);
    return i < kWeightDisplayNames.size() ? kWeightDisplayNames[i] : "Regular";
}

std::optional<SystemFontWeight> systemFontWeightNamed(std::string_view name) {
    for (const SystemFontWeight weight : kSystemFontWeights) {
        if (name == nameOf(weight)) {
            return weight;
        }
    }
    return std::nullopt;
}

std::string TitleFont::displayName() const {
    if (isSystem) {
        return std::string("System ") + displayNameOf(weight);
    }
    if (family.empty() && style.empty()) {
        return postScriptName;
    }
    return style.empty() ? family : family.empty() ? style : family + " " + style;
}

const TitleParameterInfo &infoOf(TitleParameter parameter) {
    const auto index = static_cast<std::size_t>(parameter);
    return index < std::size(kTitleTable) ? kTitleTable[index] : kTitleTable[0];
}

const char *nameOf(TitleParameter parameter) {
    return infoOf(parameter).name;
}

const char *displayNameOf(TitleParameter parameter) {
    return infoOf(parameter).displayName;
}

std::optional<TitleParameter> titleParameterNamed(std::string_view name) {
    for (const TitleParameterInfo &row : kTitleTable) {
        if (name == row.name) {
            return row.parameter;
        }
    }
    return std::nullopt;
}

TitleValue valueOf(const TitleContent &c, TitleParameter parameter) {
    switch (parameter) {
    case TitleParameter::Text:
        return c.text;
    case TitleParameter::Font:
        return c.font;
    case TitleParameter::Size:
        return c.size;
    case TitleParameter::FillColour:
        return c.fillColour;
    case TitleParameter::Alignment:
        return c.alignment;
    case TitleParameter::LineSpacing:
        return c.lineSpacing;
    case TitleParameter::Tracking:
        return c.tracking;
    case TitleParameter::Outline:
        return c.outline;
    case TitleParameter::OutlineColour:
        return c.outlineColour;
    case TitleParameter::OutlineWidth:
        return c.outlineWidth;
    case TitleParameter::Shadow:
        return c.shadow;
    case TitleParameter::ShadowColour:
        return c.shadowColour;
    case TitleParameter::ShadowOpacity:
        return c.shadowOpacity;
    case TitleParameter::ShadowAngle:
        return c.shadowAngle;
    case TitleParameter::ShadowDistance:
        return c.shadowDistance;
    case TitleParameter::ShadowBlur:
        return c.shadowBlur;
    case TitleParameter::Box:
        return c.box;
    case TitleParameter::BoxColour:
        return c.boxColour;
    case TitleParameter::BoxOpacity:
        return c.boxOpacity;
    case TitleParameter::BoxPadding:
        return c.boxPadding;
    case TitleParameter::BoxCornerRadius:
        return c.boxCornerRadius;
    case TitleParameter::PositionX:
        return c.x;
    case TitleParameter::PositionY:
        return c.y;
    case TitleParameter::BoxWidth:
        return c.width;
    }
    return c.text;
}

namespace {

template <class V> bool assign(V &field, const TitleValue &value) {
    if (const V *v = std::get_if<V>(&value)) {
        field = *v;
        return true;
    }
    return false;
}

} // namespace

bool setValue(TitleContent &c, TitleParameter parameter, const TitleValue &value) {
    switch (parameter) {
    case TitleParameter::Text:
        return assign(c.text, value);
    case TitleParameter::Font:
        return assign(c.font, value);
    case TitleParameter::Size:
        return assign(c.size, value);
    case TitleParameter::FillColour:
        return assign(c.fillColour, value);
    case TitleParameter::Alignment:
        return assign(c.alignment, value);
    case TitleParameter::LineSpacing:
        return assign(c.lineSpacing, value);
    case TitleParameter::Tracking:
        return assign(c.tracking, value);
    case TitleParameter::Outline:
        return assign(c.outline, value);
    case TitleParameter::OutlineColour:
        return assign(c.outlineColour, value);
    case TitleParameter::OutlineWidth:
        return assign(c.outlineWidth, value);
    case TitleParameter::Shadow:
        return assign(c.shadow, value);
    case TitleParameter::ShadowColour:
        return assign(c.shadowColour, value);
    case TitleParameter::ShadowOpacity:
        return assign(c.shadowOpacity, value);
    case TitleParameter::ShadowAngle:
        return assign(c.shadowAngle, value);
    case TitleParameter::ShadowDistance:
        return assign(c.shadowDistance, value);
    case TitleParameter::ShadowBlur:
        return assign(c.shadowBlur, value);
    case TitleParameter::Box:
        return assign(c.box, value);
    case TitleParameter::BoxColour:
        return assign(c.boxColour, value);
    case TitleParameter::BoxOpacity:
        return assign(c.boxOpacity, value);
    case TitleParameter::BoxPadding:
        return assign(c.boxPadding, value);
    case TitleParameter::BoxCornerRadius:
        return assign(c.boxCornerRadius, value);
    case TitleParameter::PositionX:
        return assign(c.x, value);
    case TitleParameter::PositionY:
        return assign(c.y, value);
    case TitleParameter::BoxWidth:
        return assign(c.width, value);
    }
    return false;
}

std::optional<std::string> titleValueProblem(TitleParameter parameter, const TitleValue &value) {
    const TitleParameterInfo &info = infoOf(parameter);
    const std::string what = std::string("The title's ") + info.displayName;
    switch (info.type) {
    case TitleValueType::Text: {
        const auto *text = std::get_if<std::string>(&value);
        if (text == nullptr) {
            return what + " must be text.";
        }
        if (text->size() > kMaxTitleTextBytes) {
            return what + " is longer than " + std::to_string(kMaxTitleTextBytes) + " bytes.";
        }
        if (!isUTF8(*text)) {
            return what + " is not valid UTF-8.";
        }
        return std::nullopt;
    }
    case TitleValueType::Font: {
        const auto *font = std::get_if<TitleFont>(&value);
        if (font == nullptr) {
            return what + " must be a font.";
        }
        if (font->isSystem) {
            if (static_cast<std::size_t>(font->weight) >= kSystemFontWeights.size()) {
                return what + " has an unknown weight of the system font.";
            }
            if (!font->postScriptName.empty() || !font->family.empty() || !font->style.empty()) {
                return what + ": the system font is named by its weight only.";
            }
            return std::nullopt;
        }
        if (font->postScriptName.empty()) {
            return what + " needs a font name.";
        }
        for (const std::string *name : {&font->postScriptName, &font->family, &font->style}) {
            if (name->size() > 1024 || !isUTF8(*name)) {
                return what + " has a name that is not valid UTF-8 or is too long.";
            }
        }
        return std::nullopt;
    }
    case TitleValueType::Number: {
        const auto *number = std::get_if<double>(&value);
        if (number == nullptr) {
            return what + " must be a number.";
        }
        if (!std::isfinite(*number) || *number < info.minimum || *number > info.maximum) {
            return what + " must be a number from " + numberText(info.minimum) + " to " + numberText(info.maximum) +
                   " (not " + numberText(*number) + ").";
        }
        return std::nullopt;
    }
    case TitleValueType::Colour: {
        const auto *colour = std::get_if<SRGBColour>(&value);
        if (colour == nullptr) {
            return what + " must be a colour.";
        }
        if (!isValidColour(*colour)) {
            return what + " must have red, green and blue from 0 to 1.";
        }
        return std::nullopt;
    }
    case TitleValueType::Choice: {
        const auto *alignment = std::get_if<TitleAlignment>(&value);
        if (alignment == nullptr) {
            return what + " must be left, centre or right.";
        }
        if (static_cast<int>(*alignment) < 0 || static_cast<int>(*alignment) > 2) {
            return what + " must be left, centre or right.";
        }
        return std::nullopt;
    }
    case TitleValueType::Toggle:
        if (!std::holds_alternative<bool>(value)) {
            return what + " must be on or off.";
        }
        return std::nullopt;
    }
    return what + " has an unknown type.";
}

std::optional<std::string> titleContentProblem(const TitleContent &content) {
    for (const TitleParameter parameter : kTitleParameters) {
        if (auto problem = titleValueProblem(parameter, valueOf(content, parameter))) {
            return problem;
        }
    }
    return std::nullopt;
}

const char *displayNameOf(GeneratedPreset preset) {
    switch (preset) {
    case GeneratedPreset::Title:
        return "Title";
    case GeneratedPreset::LowerThird:
        return "Lower Third";
    case GeneratedPreset::ColourMatte:
        return "Colour Matte";
    }
    return "Title";
}

GeneratorKind generatorKindOf(GeneratedPreset preset) {
    return preset == GeneratedPreset::ColourMatte ? GeneratorKind::ColourMatte : GeneratorKind::Title;
}

TitleContent titlePreset(GeneratedPreset preset) {
    TitleContent content; // the Title preset: the defaults
    if (preset == GeneratedPreset::LowerThird) {
        // Left-aligned in the lower left, inside title-safe (90 % of the frame: a 5 % margin), two lines on a
        // 60 % black box with padding; no shadow (the box carries the text).
        content.text = "Name\nRole";
        content.size = 0.045;
        content.alignment = TitleAlignment::Left;
        content.shadow = false;
        content.box = true;
        content.boxColour = kBlack;
        content.boxOpacity = 0.6;
        content.boxPadding = 0.015;
        content.width = 0.4;
        // The text's left edge just inside title-safe: the 5 % margin plus the box's padding (0.015 of the
        // height is 0.0084 of a 16:9 frame's width); its centre about four fifths of the way down.
        content.x = 0.26;
        content.y = 0.8;
    }
    return content;
}

ContentId contentIdOf(const TitleContent &content) {
    Fnv128 hash;
    hash.text("framewright.title.1");
    for (const TitleParameter parameter : kTitleParameters) {
        const TitleParameterInfo &info = infoOf(parameter);
        if (!info.changesPixels) {
            continue;
        }
        hash.text(info.name);
        const TitleValue value = valueOf(content, parameter);
        std::visit(
            [&hash](const auto &v) {
                using V = std::decay_t<decltype(v)>;
                if constexpr (std::is_same_v<V, std::string>) {
                    hash.text(v);
                } else if constexpr (std::is_same_v<V, TitleFont>) {
                    hash.flag(v.isSystem);
                    hash.text(v.isSystem ? nameOf(v.weight) : "");
                    hash.text(v.postScriptName);
                    hash.text(v.family);
                    hash.text(v.style);
                } else if constexpr (std::is_same_v<V, double>) {
                    hash.number(v);
                } else if constexpr (std::is_same_v<V, SRGBColour>) {
                    hash.colour(v);
                } else if constexpr (std::is_same_v<V, TitleAlignment>) {
                    hash.text(nameOf(v));
                } else {
                    hash.flag(v);
                }
            },
            value);
    }
    return hash.id();
}

ContentId matteContentIdOf(const SRGBColour &colour) {
    Fnv128 hash;
    hash.text("framewright.matte.1");
    hash.colour(colour);
    return hash.id();
}

ContentId contentIdOnCanvas(const ContentId &id, std::int32_t width, std::int32_t height) {
    Fnv128 hash;
    hash.text("framewright.canvas.1");
    hash.bytes(&id.high, sizeof id.high);
    hash.bytes(&id.low, sizeof id.low);
    hash.bytes(&width, sizeof width);
    hash.bytes(&height, sizeof height);
    return hash.id();
}

std::shared_ptr<const GeneratedContent> GeneratedContent::makeTitle(TitleContent title, std::string foreign) {
    auto content = std::shared_ptr<GeneratedContent>(new GeneratedContent());
    content->kind_ = GeneratorKind::Title;
    content->title_ = std::move(title);
    content->foreign_ = std::move(foreign);
    content->contentId_ = contentIdOf(content->title_);
    return content;
}

std::shared_ptr<const GeneratedContent> GeneratedContent::makeMatte(SRGBColour colour, std::string foreign) {
    auto content = std::shared_ptr<GeneratedContent>(new GeneratedContent());
    content->kind_ = GeneratorKind::ColourMatte;
    content->matteColour_ = colour;
    content->foreign_ = std::move(foreign);
    content->contentId_ = matteContentIdOf(colour);
    return content;
}

std::shared_ptr<const GeneratedContent> GeneratedContent::makePreset(GeneratedPreset preset) {
    return preset == GeneratedPreset::ColourMatte ? makeMatte(kBlack) : makeTitle(titlePreset(preset));
}

bool operator==(const GeneratedContent &a, const GeneratedContent &b) {
    if (a.kind_ != b.kind_ || a.foreign_ != b.foreign_) {
        return false;
    }
    return a.kind_ == GeneratorKind::ColourMatte ? a.matteColour_ == b.matteColour_ : a.title_ == b.title_;
}

bool sameContent(const std::shared_ptr<const GeneratedContent> &a, const std::shared_ptr<const GeneratedContent> &b) {
    if (!a || !b) {
        return !a && !b;
    }
    return a == b || *a == *b;
}

std::optional<std::string> generatedContentProblem(const GeneratedContent &content) {
    switch (content.kind()) {
    case GeneratorKind::Title:
        return titleContentProblem(content.title());
    case GeneratorKind::ColourMatte:
        if (!isValidColour(content.matteColour())) {
            return std::string("The matte's colour must have red, green and blue from 0 to 1.");
        }
        return std::nullopt;
    case GeneratorKind::None:
        break;
    }
    return std::string("Generated content needs a kind (a title or a colour matte).");
}

std::string titleDisplayName(const TitleContent &content) {
    const std::string &text = content.text;
    std::size_t start = 0;
    while (start < text.size()) {
        std::size_t end = text.find('\n', start);
        if (end == std::string::npos) {
            end = text.size();
        }
        std::string line = text.substr(start, end - start);
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.find_first_not_of(" \t") != std::string::npos) {
            return line;
        }
        start = end + 1;
    }
    return "Title";
}

} // namespace ve
