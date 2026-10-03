// Titles and colour mattes in the project file (schema 10; titles design, sections 1 and 12): the writer and
// the parser round trip bit for bit, unknown keys in a title or matte are kept with a warning and written back,
// an unknown generator or content kind is refused with a message naming its path, values outside their range
// are limited with a warning, values of the wrong type fail with their path, and the system font is saved as a
// weight, a missing font by its name, unchanged.

#include "../Model/ModelFixtures.h"

#include <algorithm>

using namespace vetest;
using nlohmann::json;

namespace {

struct TitleFixture : Fixture {
    AssetId titles;
    AssetId mattes;
    ClipId title;
    ClipId matte;

    TitleFixture() {
        titles = project.addAsset(makeGeneratorAsset(GeneratorKind::Title));
        mattes = project.addAsset(makeGeneratorAsset(GeneratorKind::ColourMatte));
        TitleContent content = titlePreset(GeneratedPreset::LowerThird);
        content.text = "Zoë Ångström — 日本語 🎬\n\"Quoted\" \\ back";
        content.font = TitleFont::named("Avenir-Heavy", "Avenir", "Heavy");
        content.tracking = -25.0;
        content.fillColour = SRGBColour{0.1, 0.2, 0.3};
        title = addClip(v2, titles, 0, 90);
        sequence().findClip(title)->generated = GeneratedContent::makeTitle(content);
        matte = addClip(v2, mattes, 120, 30);
        sequence().findClip(matte)->generated = GeneratedContent::makeMatte(SRGBColour{0.5, 0.25, 1.0});
        requireValid();
    }
};

json &clipJsonIn(json &document, ClipId id) {
    for (json &sequence : document.at("sequences")) {
        for (const char *kind : {"videoTracks", "audioTracks"}) {
            for (json &track : sequence.at(kind)) {
                for (json &clip : track.at("clips")) {
                    if (clip.at("id") == id.value()) {
                        return clip;
                    }
                }
            }
        }
    }
    FAIL("clip not in the file");
    static json none;
    return none;
}

bool anyContains(const std::vector<std::string> &list, const std::string &needle) {
    return std::any_of(list.begin(), list.end(),
                       [&](const std::string &s) { return s.find(needle) != std::string::npos; });
}

std::string loadError(const json &document) {
    const ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_FALSE(loaded.ok());
    return loaded.error;
}

} // namespace

TEST_CASE("Generated content JSON: titles and mattes round trip bit for bit") {
    const TitleFixture fx;
    const json document = projectToJson(fx.project);
    const json &title = clipJsonIn(const_cast<json &>(document), fx.title).at("generated");
    CHECK(title.at("kind") == "title");
    // Every parameter is written, by its table name.
    for (const TitleParameter parameter : kTitleParameters) {
        CHECK(title.contains(nameOf(parameter)));
    }
    CHECK(title.size() == kTitleParameterCount + 1);
    CHECK(title.at("alignment") == "left");
    CHECK(title.at("fillColour") == json::array({0.1, 0.2, 0.3}));
    CHECK(title.at("font") == json{{"name", "Avenir-Heavy"}, {"family", "Avenir"}, {"style", "Heavy"}});
    CHECK(clipJsonIn(const_cast<json &>(document), fx.matte).at("generated") ==
          json{{"kind", "colourMatte"}, {"colour", json::array({0.5, 0.25, 1.0})}});
    const ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == fx.project);
    CHECK(serializeProject(*loaded.project) == serializeProject(fx.project));
    const ProjectLoadResult text = parseProject(serializeProject(fx.project));
    REQUIRE(text.ok());
    CHECK(*text.project == fx.project);
    // The content ids survive (they are recomputed from the same values).
    CHECK(text.project->sequences[0].findClip(fx.title)->generated->contentId() ==
          fx.clip(fx.title).generated->contentId());
    // A generator asset says so; a file asset writes what version 9 wrote.
    for (const json &asset : document.at("assets")) {
        const bool generator = asset.at("id") == fx.titles.value() || asset.at("id") == fx.mattes.value();
        CHECK(asset.contains("generator") == generator);
        CHECK(asset.contains("generated") == false);
    }
}

TEST_CASE("Generated content JSON: unknown keys are kept with a warning and written back") {
    const TitleFixture fx;
    json document = projectToJson(fx.project);
    clipJsonIn(document, fx.title)["generated"]["glow"] = json{{"radius", 0.02}, {"colour", "gold"}};
    clipJsonIn(document, fx.matte)["generated"]["gradient"] = "radial";
    const ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    REQUIRE(loaded.warnings.size() == 2);
    CHECK(loaded.warnings[0] == "sequences[0].videoTracks[1].clips[0].generated.glow: unknown title parameter \"glow\" "
                                "(from a newer version of Framewright?); kept as it is and saved with the project, but "
                                "not drawn or editable");
    CHECK(anyContains(loaded.warnings, "generated.gradient: unknown matte parameter \"gradient\""));
    const Clip &title = *loaded.project->sequences[0].findClip(fx.title);
    CHECK(title.generated->foreign() == "{\"glow\":{\"colour\":\"gold\",\"radius\":0.02}}");
    CHECK(title.generated->contentId() == fx.clip(fx.title).generated->contentId()); // drawn the same here
    CHECK_FALSE(*loaded.project == fx.project);                                       // but kept
    json saved = projectToJson(*loaded.project);
    CHECK(clipJsonIn(saved, fx.title).at("generated").at("glow") == json{{"radius", 0.02}, {"colour", "gold"}});
    CHECK(clipJsonIn(saved, fx.matte).at("generated").at("gradient") == "radial");
}

TEST_CASE("Generated content JSON: unknown kinds are refused naming their path") {
    const TitleFixture fx;
    json document = projectToJson(fx.project);
    json assetShape = document;
    for (json &asset : assetShape.at("assets")) {
        if (asset.at("id") == fx.titles.value()) {
            asset["generator"] = "shape";
        }
    }
    CHECK(loadError(assetShape) ==
          "assets[5].generator: unknown generator kind \"shape\" (from a newer version of Framewright?)");
    json clipShape = document;
    clipJsonIn(clipShape, fx.title)["generated"]["kind"] = "shape";
    CHECK(loadError(clipShape) == "sequences[0].videoTracks[1].clips[0].generated.kind: unknown generated content kind "
                                  "\"shape\" (from a newer version of Framewright?)");
    json none = document;
    clipJsonIn(none, fx.title)["generated"]["kind"] = "none";
    CHECK(loadError(none).find("generated.kind: unknown generated content kind \"none\"") != std::string::npos);
    // A clip of a generator asset without content, or with another kind's, is not a valid project.
    json missing = document;
    clipJsonIn(missing, fx.title).erase("generated");
    CHECK(loadError(missing).find("a clip of the Title generator has no content") != std::string::npos);
    json swapped = document;
    clipJsonIn(swapped, fx.title)["generated"] = json{{"kind", "colourMatte"}, {"colour", json::array({0, 0, 0})}};
    CHECK(loadError(swapped).find("Colour Matte content on a clip of the Title generator") != std::string::npos);
    // The title asset turned into a file: its clip's content no longer belongs.
    json onMedia = document;
    for (json &asset : onMedia.at("assets")) {
        if (asset.at("id") == fx.titles.value()) {
            asset.erase("generator");
            asset["url"] = "file:///media/title.png";
            asset["width"] = 1920;
            asset["height"] = 1080;
        }
    }
    CHECK(loadError(onMedia).find("a clip of media has no generated content") != std::string::npos);
}

TEST_CASE("Generated content JSON: values out of range are limited, values of the wrong type fail") {
    const TitleFixture fx;
    json document = projectToJson(fx.project);
    json &generated = clipJsonIn(document, fx.title)["generated"];
    generated["size"] = 0.0;
    generated["boxOpacity"] = 7;
    generated["shadowColour"] = json::array({-0.5, 0.5, 1.5});
    generated["font"] = json{{"system", "extraBlack"}};
    generated["alignment"] = "justified";
    const ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(anyContains(loaded.warnings, "generated.size: Size 0.0 is outside its range [0.005, 1.0]; limited to 0.005"));
    CHECK(anyContains(loaded.warnings, "generated.boxOpacity: Box Opacity 7 is outside its range [0.0, 1.0]; limited to 1.0"));
    CHECK(anyContains(loaded.warnings, "generated.shadowColour: the title's Shadow Colour [-0.5,0.5,1.5] has a component "
                                       "outside [0, 1]; limited to [0.0,0.5,1.0]"));
    CHECK(anyContains(loaded.warnings, "generated.font.system: unknown weight \"extraBlack\" of the system font (from a "
                                       "newer version of Framewright?); using Regular"));
    CHECK(anyContains(loaded.warnings, "generated.alignment: unknown alignment \"justified\""));
    const TitleContent &title = loaded.project->sequences[0].findClip(fx.title)->generated->title();
    CHECK(title.size == 0.005);
    CHECK(title.boxOpacity == 1.0);
    CHECK(title.shadowColour == SRGBColour{0.0, 0.5, 1.0});
    CHECK(title.font == TitleFont::system(SystemFontWeight::Regular));
    CHECK(title.alignment == TitleAlignment::Centre);

    auto failsWith = [&](const char *key, json value, const std::string &message) {
        json broken = projectToJson(fx.project);
        clipJsonIn(broken, fx.title)["generated"][key] = std::move(value);
        CHECK(loadError(broken) == "sequences[0].videoTracks[1].clips[0].generated." + std::string(key) + message);
    };
    failsWith("size", "big", ": expected a number, found string");
    failsWith("text", 12, ": expected a string, found number");
    failsWith("box", 1, ": expected a boolean, found number");
    failsWith("fillColour", json::array({1, 1}), ": expected a colour [r, g, b]");
    failsWith("font", json{{"family", "Helvetica"}}, ".name: missing required field");
    failsWith("text", std::string(kMaxTitleTextBytes + 1, 'x'),
              ": The title's Text is longer than " + std::to_string(kMaxTitleTextBytes) + " bytes.");
    json noKind = projectToJson(fx.project);
    clipJsonIn(noKind, fx.matte)["generated"].erase("kind");
    CHECK(loadError(noKind).find("generated.kind") != std::string::npos);
    // Parameters left out have their defaults.
    json sparse = projectToJson(fx.project);
    clipJsonIn(sparse, fx.title)["generated"] = json{{"kind", "title"}, {"text", "Only text"}};
    const ProjectLoadResult defaults = projectFromJson(sparse);
    REQUIRE(defaults.ok());
    TitleContent expected;
    expected.text = "Only text";
    CHECK(defaults.project->sequences[0].findClip(fx.title)->generated->title() == expected);
}

TEST_CASE("Generated content JSON: a grade on a title or matte is dropped with a warning") {
    const TitleFixture fx;
    json document = projectToJson(fx.project);
    clipJsonIn(document, fx.matte)["grade"] = json{{"saturation", 0.0}};
    const ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings ==
          std::vector<std::string>{"clip " + std::to_string(fx.matte.value()) + ": a Colour Matte clip has no grade; dropped"});
    CHECK(loaded.project->sequences[0].findClip(fx.matte)->grade.isEmpty());
}

TEST_CASE("Generated content JSON: fonts are saved by weight or by name, unchanged") {
    TitleFixture fx;
    TitleContent missing;
    missing.font = TitleFont::named("NoSuchFont-Bold", "No Such Font", "Bold");
    fx.sequence().findClip(fx.title)->generated = GeneratedContent::makeTitle(missing);
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE(loaded.ok());
    CHECK(loaded.warnings.empty()); // a font this Mac lacks is the renderer's to report, not the file's
    CHECK(loaded.project->sequences[0].findClip(fx.title)->generated->title().font == missing.font);
    TitleContent system;
    system.font = TitleFont::system(SystemFontWeight::UltraLight);
    fx.sequence().findClip(fx.title)->generated = GeneratedContent::makeTitle(system);
    json document = projectToJson(fx.project);
    CHECK(clipJsonIn(document, fx.title).at("generated").at("font") == json{{"system", "ultraLight"}});
}
