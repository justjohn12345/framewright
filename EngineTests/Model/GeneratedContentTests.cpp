// Generated clips in the model (titles design, sections 1, 3, 6 and 12; slice 1, item 3): the title parameter
// table, values and their ranges, the content id (every pixel parameter changes it, the position does not),
// equality, the presets, maxMotionScale against hand-computed span sets (an overshooting custom curve among
// them), and the validation rules: generator assets are stills without a file or a size, a clip of one carries
// content of its kind and no grade, a clip of media carries none, and only video tracks take them.

#include "ModelFixtures.h"

#include <cmath>
#include <limits>
#include <set>

using namespace vetest;

namespace {

// A project fixture with the two generator assets.
struct GeneratedFixture : Fixture {
    AssetId titles;
    AssetId mattes;

    GeneratedFixture() {
        titles = project.addAsset(makeGeneratorAsset(GeneratorKind::Title));
        mattes = project.addAsset(makeGeneratorAsset(GeneratorKind::ColourMatte));
    }

    ClipId addGenerated(TrackId trackId, AssetId assetId, std::shared_ptr<const GeneratedContent> content,
                        std::int64_t startFrame, std::int64_t durationFrames) {
        const ClipId id = addClip(trackId, assetId, startFrame, durationFrames);
        sequence().findClip(id)->generated = std::move(content);
        return id;
    }
};

TitleValue sampleValueOtherThanDefault(TitleParameter parameter) {
    const TitleParameterInfo &info = infoOf(parameter);
    switch (info.type) {
    case TitleValueType::Text:
        return std::string("Another text");
    case TitleValueType::Font:
        return TitleFont::named("Helvetica-Bold", "Helvetica", "Bold");
    case TitleValueType::Number:
        return info.defaultValue == info.maximum ? info.minimum : (info.defaultValue + info.maximum) / 2.0;
    case TitleValueType::Colour:
        return SRGBColour{0.25, 0.5, 0.75};
    case TitleValueType::Choice:
        return TitleAlignment::Right;
    case TitleValueType::Toggle:
        return !std::get<bool>(valueOf(TitleContent{}, parameter));
    case TitleValueType::Anchor:
        return TitleAnchor::Bottom;
    }
    return std::string();
}

} // namespace

TEST_CASE("Generated content: the title parameter table") {
    std::set<std::string> names;
    REQUIRE(kTitleParameters.size() == kTitleParameterCount);
    for (std::size_t i = 0; i < kTitleParameterCount; ++i) {
        const TitleParameter parameter = kTitleParameters[i];
        const TitleParameterInfo &info = infoOf(parameter);
        CAPTURE(info.name);
        CHECK(static_cast<std::size_t>(parameter) == i);
        CHECK(info.parameter == parameter);
        CHECK(names.insert(info.name).second);
        CHECK(titleParameterNamed(info.name) == parameter);
        CHECK(std::string(displayNameOf(parameter)) == info.displayName);
        // The default content holds every number's default, and is valid.
        if (info.type == TitleValueType::Number) {
            CHECK(std::get<double>(valueOf(TitleContent{}, parameter)) == info.defaultValue);
        }
        if (info.type == TitleValueType::Toggle) {
            CHECK(std::get<bool>(valueOf(TitleContent{}, parameter)) == (info.defaultValue != 0));
        }
        CHECK(info.changesPixels == (parameter != TitleParameter::PositionX && parameter != TitleParameter::PositionY));
    }
    CHECK_FALSE(titleParameterNamed("lift").has_value());
    CHECK_FALSE(titleContentProblem(TitleContent{}).has_value());
    // The design's defaults: the system font Semibold, 0.06 of the height, white and centred, a 50 % black
    // shadow at distance 0.003 and blur 0.004, outline and box off, centred, 0.8 of the width.
    const TitleContent d;
    CHECK(d.font == TitleFont::system(SystemFontWeight::Semibold));
    CHECK(d.size == 0.06);
    CHECK(d.fillColour == kWhite);
    CHECK(d.alignment == TitleAlignment::Centre);
    CHECK(d.shadow);
    CHECK(d.shadowColour == kBlack);
    CHECK(d.shadowOpacity == 0.5);
    CHECK(d.shadowDistance == 0.003);
    CHECK(d.shadowBlur == 0.004);
    CHECK_FALSE(d.outline);
    CHECK_FALSE(d.box);
    CHECK(d.x == 0.5);
    CHECK(d.y == 0.5);
    CHECK(d.width == 0.8);
    CHECK(d.lineSpacing == 1.0);
    CHECK(d.tracking == 0.0);
    // Schema 11: area text anchored at its centre, as slice 1 drew every title.
    CHECK_FALSE(d.pointText);
    CHECK(d.anchor == TitleAnchor::Centre);
}

TEST_CASE("Generated content: the vertical anchor's names and values") {
    for (const TitleAnchor anchor : {TitleAnchor::Top, TitleAnchor::Centre, TitleAnchor::Bottom}) {
        CAPTURE(nameOf(anchor));
        CHECK(titleAnchorNamed(nameOf(anchor)) == anchor);
        CHECK_FALSE(titleValueProblem(TitleParameter::Anchor, anchor).has_value());
    }
    CHECK(std::string(nameOf(TitleAnchor::Top)) == "top");
    CHECK(std::string(nameOf(TitleAnchor::Bottom)) == "bottom");
    CHECK_FALSE(titleAnchorNamed("middle").has_value());
    CHECK(titleValueProblem(TitleParameter::Anchor, static_cast<TitleAnchor>(7)).value_or("") ==
          "The title's Vertical Anchor must be top, centre or bottom.");
    CHECK(titleValueProblem(TitleParameter::Anchor, TitleAlignment::Left).has_value());
    CHECK(titleValueProblem(TitleParameter::PointText, TitleAnchor::Top).value_or("") ==
          "The title's Point Text must be on or off.");
    // Both change the picture's identity (they place it relative to the position).
    TitleContent point;
    point.pointText = true;
    CHECK(contentIdOf(point) != contentIdOf(TitleContent{}));
    TitleContent top;
    top.anchor = TitleAnchor::Top;
    CHECK(contentIdOf(top) != contentIdOf(TitleContent{}));
    TitleContent bottom;
    bottom.anchor = TitleAnchor::Bottom;
    CHECK(contentIdOf(top) != contentIdOf(bottom));
}

TEST_CASE("Generated content: values are set and read by parameter, of their own type") {
    for (const TitleParameter parameter : kTitleParameters) {
        CAPTURE(nameOf(parameter));
        TitleContent content;
        const TitleValue value = sampleValueOtherThanDefault(parameter);
        CHECK(value != valueOf(content, parameter));
        CHECK_FALSE(titleValueProblem(parameter, value).has_value());
        REQUIRE(setValue(content, parameter, value));
        CHECK(valueOf(content, parameter) == value);
        // Only that parameter changed.
        for (const TitleParameter other : kTitleParameters) {
            if (other != parameter) {
                CHECK(valueOf(content, other) == valueOf(TitleContent{}, other));
            }
        }
        // A value of another type is refused and changes nothing.
        const TitleValue wrong = infoOf(parameter).type == TitleValueType::Toggle ? TitleValue(0.5) : TitleValue(true);
        TitleContent unchanged;
        CHECK_FALSE(setValue(unchanged, parameter, wrong));
        CHECK(unchanged == TitleContent{});
        CHECK(titleValueProblem(parameter, wrong).has_value());
    }
}

TEST_CASE("Generated content: what a value may be") {
    CHECK(titleValueProblem(TitleParameter::Size, 0.0).value_or("") ==
          "The title's Size must be a number from 0.005 to 1 (not 0).");
    CHECK(titleValueProblem(TitleParameter::Size, std::numeric_limits<double>::quiet_NaN()).has_value());
    CHECK(titleValueProblem(TitleParameter::ShadowOpacity, 1.5).has_value());
    CHECK(titleValueProblem(TitleParameter::BoxWidth, 4.0) == std::nullopt);
    CHECK(titleValueProblem(TitleParameter::PositionX, -1.0) == std::nullopt);
    CHECK(titleValueProblem(TitleParameter::PositionX, 2.5).has_value());
    CHECK(titleValueProblem(TitleParameter::FillColour, SRGBColour{1.2, 0, 0}).value_or("") ==
          "The title's Fill Colour must have red, green and blue from 0 to 1.");
    CHECK(titleValueProblem(TitleParameter::Text, std::string("")) == std::nullopt);
    CHECK(titleValueProblem(TitleParameter::Text, std::string("Zoë 日本語 🎬\nline two")) == std::nullopt);
    CHECK(titleValueProblem(TitleParameter::Text, std::string("bad \xC3\x28 byte")).value_or("") ==
          "The title's Text is not valid UTF-8.");
    CHECK(titleValueProblem(TitleParameter::Text, std::string("\xED\xA0\x80")).has_value()); // a surrogate
    CHECK(titleValueProblem(TitleParameter::Text, std::string("\xC0\x80")).has_value());     // an overlong NUL
    CHECK(titleValueProblem(TitleParameter::Text, std::string(kMaxTitleTextBytes + 1, 'a')).has_value());
    CHECK(titleValueProblem(TitleParameter::Text, std::string(kMaxTitleTextBytes, 'a')) == std::nullopt);
    CHECK(titleValueProblem(TitleParameter::Font, TitleFont::named("", "Helvetica", "Bold")).value_or("") ==
          "The title's Font needs a font name.");
    TitleFont systemWithName = TitleFont::system(SystemFontWeight::Bold);
    systemWithName.postScriptName = ".SFNS-Bold";
    CHECK(titleValueProblem(TitleParameter::Font, systemWithName).has_value());
    CHECK(titleValueProblem(TitleParameter::Font, TitleFont::named("NoSuchFont-Bold", "No Such Font", "Bold")) ==
          std::nullopt);
    CHECK(TitleFont::system(SystemFontWeight::Semibold).displayName() == "System Semibold");
    CHECK(TitleFont::named("Helvetica-Bold", "Helvetica", "Bold").displayName() == "Helvetica Bold");
    CHECK(TitleFont::named("Helvetica-Bold", "", "").displayName() == "Helvetica-Bold");
    for (const SystemFontWeight weight : kSystemFontWeights) {
        CHECK(systemFontWeightNamed(nameOf(weight)) == weight);
    }
    for (const TitleAlignment alignment : {TitleAlignment::Left, TitleAlignment::Centre, TitleAlignment::Right}) {
        CHECK(titleAlignmentNamed(nameOf(alignment)) == alignment);
    }
    for (const GeneratorKind kind : {GeneratorKind::None, GeneratorKind::Title, GeneratorKind::ColourMatte}) {
        CHECK(generatorKindNamed(nameOf(kind)) == kind);
    }
    CHECK(std::string(nameOf(GeneratorKind::ColourMatte)) == "colourMatte");
    CHECK(std::string(displayNameOf(GeneratorKind::ColourMatte)) == "Colour Matte");
}

TEST_CASE("Generated content: the content id covers every pixel parameter and not the position") {
    const ContentId base = contentIdOf(TitleContent{});
    CHECK(contentIdOf(TitleContent{}) == base);
    std::set<ContentId> seen{base};
    for (const TitleParameter parameter : kTitleParameters) {
        CAPTURE(nameOf(parameter));
        TitleContent content;
        REQUIRE(setValue(content, parameter, sampleValueOtherThanDefault(parameter)));
        const ContentId id = contentIdOf(content);
        if (infoOf(parameter).changesPixels) {
            CHECK(id != base);
            CHECK(seen.insert(id).second); // each parameter's change gives an id of its own
        } else {
            CHECK(id == base); // a drag of the box renders nothing new
        }
    }
    // Small changes count: one character, a thousandth of the size, the font's family name, a colour's last bit.
    TitleContent typed;
    typed.text = "Titlf";
    CHECK(contentIdOf(typed) != base);
    TitleContent nudged;
    nudged.size = 0.06 + 1e-12;
    CHECK(contentIdOf(nudged) != base);
    TitleContent white;
    white.fillColour = SRGBColour{1.0, 1.0, std::nextafter(1.0, 0.0)};
    CHECK(contentIdOf(white) != base);
    TitleContent negativeZero;
    negativeZero.tracking = -0.0;
    CHECK(contentIdOf(negativeZero) == base); // -0 and +0 draw alike
    // Text that moves a character between the text and another field still differs (lengths are hashed).
    TitleContent a, b;
    a.text = "ab";
    a.font = TitleFont::named("c", "", "");
    b.text = "a";
    b.font = TitleFont::named("bc", "", "");
    CHECK(contentIdOf(a) != contentIdOf(b));
    // Mattes: the colour, in a namespace of their own.
    CHECK(matteContentIdOf(kBlack) == matteContentIdOf(kBlack));
    CHECK(matteContentIdOf(kBlack) != matteContentIdOf(SRGBColour{0, 0, 1.0 / 255.0}));
    CHECK(matteContentIdOf(kBlack) != base);
    // The content object computes it once.
    auto title = GeneratedContent::makeTitle(typed);
    CHECK(title->contentId() == contentIdOf(typed));
    CHECK(GeneratedContent::makeMatte(kWhite)->contentId() == matteContentIdOf(kWhite));
}

TEST_CASE("Generated content: equality compares contents and what a newer version wrote") {
    auto first = GeneratedContent::makeTitle(TitleContent{});
    auto second = GeneratedContent::makeTitle(TitleContent{});
    CHECK(first != second); // different objects
    CHECK(*first == *second);
    CHECK(sameContent(first, second));
    CHECK(sameContent(nullptr, nullptr));
    CHECK_FALSE(sameContent(first, nullptr));
    auto foreign = GeneratedContent::makeTitle(TitleContent{}, "{\"glow\":true}");
    CHECK_FALSE(sameContent(first, foreign));
    CHECK(foreign->contentId() == first->contentId()); // this version draws it the same
    CHECK_FALSE(sameContent(GeneratedContent::makeMatte(kBlack), GeneratedContent::makeTitle(TitleContent{})));
    CHECK(sameContent(GeneratedContent::makeMatte(kBlack), GeneratedContent::makePreset(GeneratedPreset::ColourMatte)));
    // Clips compare their contents.
    GeneratedFixture fx;
    const ClipId id = fx.addGenerated(fx.v2, fx.titles, first, 0, 30);
    Clip copy = fx.clip(id);
    copy.generated = second;
    CHECK(copy == fx.clip(id));
    copy.generated = GeneratedContent::makeTitle(titlePreset(GeneratedPreset::LowerThird));
    CHECK_FALSE(copy == fx.clip(id));
}

TEST_CASE("Generated content: the presets") {
    CHECK(titlePreset(GeneratedPreset::Title) == TitleContent{});
    const TitleContent lower = titlePreset(GeneratedPreset::LowerThird);
    CHECK_FALSE(titleContentProblem(lower).has_value());
    CHECK(lower.text == "Name\nRole");
    CHECK(lower.alignment == TitleAlignment::Left);
    CHECK(lower.box);
    CHECK(lower.boxColour == kBlack);
    CHECK(lower.boxOpacity == 0.6);
    // Inside title-safe (90 %): the text block's left edge right of 5 % and its centre in the lower part.
    CHECK(lower.x - lower.width / 2.0 >= 0.05);
    CHECK(lower.x + lower.width / 2.0 <= 0.95);
    CHECK(lower.y > 0.66);
    CHECK(lower.y < 0.95);
    CHECK(generatorKindOf(GeneratedPreset::LowerThird) == GeneratorKind::Title);
    CHECK(generatorKindOf(GeneratedPreset::ColourMatte) == GeneratorKind::ColourMatte);
    auto matte = GeneratedContent::makePreset(GeneratedPreset::ColourMatte);
    CHECK(matte->isMatte());
    CHECK(matte->matteColour() == kBlack);
    CHECK(std::string(displayNameOf(GeneratedPreset::LowerThird)) == "Lower Third");
}

TEST_CASE("Generated content: a title's name on the timeline is its first line") {
    TitleContent content;
    content.text = "Jane Doe\nDirector";
    CHECK(titleDisplayName(content) == "Jane Doe");
    content.text = "\n  \nSecond\r\nThird";
    CHECK(titleDisplayName(content) == "Second");
    content.text = "";
    CHECK(titleDisplayName(content) == "Title");
    content.text = "   ";
    CHECK(titleDisplayName(content) == "Title");
}

TEST_CASE("maxMotionScale: the largest scale a clip reaches, from its static scale and Motion spans") {
    GeneratedFixture fx;
    const ClipId id = fx.addGenerated(fx.v2, fx.titles, GeneratedContent::makeTitle(TitleContent{}), 0, 150);
    Clip *clip = fx.sequence().findClip(id);
    clip->video.scale = 1.25;
    CHECK(maxMotionScale(*clip) == 1.25);

    // A zoom from 1 to 2 (linear) over the first second: 1.25 x 2.
    SpanTracks zoom;
    zoom.track(SpanParameter::Scale) = {key(kCMTimeZero, 1.0), key(f30(30), 2.0)};
    fx.addSpan(id, SpanKind::Motion, 1, kCMTimeZero, f30(30), zoom);
    CHECK(maxMotionScale(*fx.sequence().findClip(id)) == 2.5);

    // A span that only shrinks contributes at most 1 (before its start the clip is at its other values).
    SpanTracks shrink;
    shrink.track(SpanParameter::Scale) = {key(kCMTimeZero, 1.0), key(f30(15), 0.5)};
    fx.addSpan(id, SpanKind::Motion, 2, f30(30), f30(45), shrink);
    CHECK(maxMotionScale(*fx.sequence().findClip(id)) == 2.5);

    // A later span on the same lane composes on top: zooming 1 -> 1.5 again gives 2.5 x 1.5.
    SpanTracks again;
    again.track(SpanParameter::Scale) = {key(kCMTimeZero, 1.0), key(f30(30), 1.5, KeyframeInterpolation::EaseInOut)};
    fx.addSpan(id, SpanKind::Motion, 1, f30(60), f30(90), again);
    CHECK(maxMotionScale(*fx.sequence().findClip(id)) == doctest::Approx(3.75).epsilon(1e-12));

    // An Opacity span is not a zoom; a span without a scale track is neutral.
    SpanTracks fade;
    fade.track(SpanParameter::Opacity) = {key(kCMTimeZero, 1.0), key(f30(10), 0.0)};
    fx.addSpan(id, SpanKind::Opacity, 3, f30(100), f30(110), fade);
    SpanTracks pan;
    pan.track(SpanParameter::X) = {key(kCMTimeZero, 0.0), key(f30(10), 300.0)};
    fx.addSpan(id, SpanKind::Motion, 2, f30(100), f30(110), pan);
    CHECK(maxMotionScale(*fx.sequence().findClip(id)) == doctest::Approx(3.75).epsilon(1e-12));
    fx.requireValid();
}

TEST_CASE("maxMotionScale: a custom curve that overshoots its keyframes") {
    GeneratedFixture fx;
    const ClipId id = fx.addGenerated(fx.v2, fx.titles, GeneratedContent::makeTitle(TitleContent{}), 0, 90);
    // From 1 to 2 with control points (0.3, 1.5) and (0.7, 1.5): the curve's fraction of the change peaks at
    // y(s) = 4.5 s - 4.5 s^2 + s^3 where y'(s) = 0, s = (3 - sqrt 3) / 2, y = 3 sqrt(3) / 4 (about 1.299).
    Keyframe start = key(kCMTimeZero, 1.0, KeyframeInterpolation::Bezier);
    start.curve = TimingCurve{0.3, 1.5, 0.7, 1.5};
    SpanTracks tracks;
    tracks.track(SpanParameter::Scale) = {start, key(f30(60), 2.0)};
    fx.addSpan(id, SpanKind::Motion, 1, kCMTimeZero, f30(60), tracks);
    const Clip &clip = fx.clip(id);
    const double expected = 1.0 + 1.0 * (3.0 * std::sqrt(3.0) / 4.0);
    CHECK(maxMotionScale(clip) == doctest::Approx(expected).epsilon(1e-12));
    // It bounds every frame's scale, and the frames come close to it.
    double largest = 0.0;
    for (std::int64_t frame = 0; frame < 90; ++frame) {
        const double scale = motionValuesAt(clip, f30(frame)).scale;
        CHECK(scale <= maxMotionScale(clip) + 1e-12);
        largest = std::max(largest, scale);
    }
    CHECK(largest > expected - 0.01);
    CHECK(largest > 2.0); // the overshoot is real: past the end keyframe

    // A curve dipping below its start (control points below 0) on a shrinking span reaches past its start
    // value upwards: from 2 down to 1, y1 = y2 = -0.5 rises above 2 first.
    GeneratedFixture dip;
    const ClipId other = dip.addGenerated(dip.v2, dip.titles, GeneratedContent::makeTitle(TitleContent{}), 0, 60);
    Keyframe high = key(kCMTimeZero, 2.0, KeyframeInterpolation::Bezier);
    high.curve = TimingCurve{0.3, -0.5, 0.7, -0.5};
    SpanTracks down;
    down.track(SpanParameter::Scale) = {high, key(f30(60), 1.0)};
    dip.addSpan(other, SpanKind::Motion, 1, kCMTimeZero, f30(60), down);
    // y(s) = -1.5 s + 1.5 s^2 + s^3 has its minimum where 3 s^2 + 3 s - 1.5 = 0, s = (sqrt(3) - 1) / 2.
    const double s = (std::sqrt(3.0) - 1.0) / 2.0;
    const double low = -1.5 * s + 1.5 * s * s + s * s * s;
    CHECK(maxMotionScale(dip.clip(other)) == doctest::Approx(2.0 - low).epsilon(1e-12));
    // A static scale of 0 hides the clip at every frame.
    dip.sequence().findClip(other)->video.scale = 0.0;
    CHECK(maxMotionScale(dip.clip(other)) == 0.0);
}

TEST_CASE("Generated content: validation of generator assets") {
    GeneratedFixture fx;
    fx.requireValid();
    const MediaAsset title = *fx.project.findAsset(fx.titles);
    CHECK(title.isGenerator());
    CHECK_FALSE(title.isFileBacked());
    CHECK(title.isStill());
    CHECK(title.name == "Title");
    CHECK(title.url.empty());
    CHECK(fx.project.findAsset(fx.mattes)->name == "Colour Matte");
    CHECK(fx.project.findAsset(fx.av30)->isFileBacked());

    MediaAsset withFile = title;
    withFile.url = "file:///media/title.png";
    CHECK(validateAsset(withFile).value_or("").find("a generator asset has no file") != std::string::npos);
    MediaAsset sized = title;
    sized.width = 1920;
    sized.height = 1080;
    CHECK(validateAsset(sized).value_or("").find("no size or rotation") != std::string::npos);
    MediaAsset video = title;
    video.kind = AssetKind::Video;
    CHECK(validateAsset(video).value_or("").find("is a still") != std::string::npos);
    // A file asset still needs its URL and size.
    MediaAsset file = *fx.project.findAsset(fx.still);
    file.url.clear();
    CHECK(validateAsset(file).value_or("").find("empty URL") != std::string::npos);
    file = *fx.project.findAsset(fx.still);
    file.width = 0;
    CHECK(validateAsset(file).has_value());
    // Equality covers the kind.
    MediaAsset other = title;
    other.generator = GeneratorKind::ColourMatte;
    CHECK_FALSE(other == title);
}

TEST_CASE("Generated content: validation of generated clips") {
    GeneratedFixture fx;
    const ClipId title = fx.addGenerated(fx.v2, fx.titles, GeneratedContent::makeTitle(TitleContent{}), 0, 150);
    const ClipId matte = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kBlack), 0, 150);
    fx.requireValid();
    auto problemWith = [&](ClipId id, const std::function<void(Clip &)> &change) {
        GeneratedFixture copy = fx;
        change(*copy.sequence().findClip(id));
        return problemOf(copy.project);
    };
    CHECK(problemWith(title, [](Clip &c) { c.generated.reset(); }).find("a clip of the Title generator has no content") !=
          std::string::npos);
    CHECK(problemWith(title, [](Clip &c) { c.generated = GeneratedContent::makeMatte(kWhite); })
              .find("Colour Matte content on a clip of the Title generator") != std::string::npos);
    CHECK(problemWith(title, [](Clip &c) { c.grade[GradeParameter::Exposure] = 1.0; })
              .find("a Title clip has no grade") != std::string::npos);
    CHECK(problemWith(matte, [](Clip &c) { c.grade[GradeParameter::Saturation] = 0.0; })
              .find("a Colour Matte clip has no grade") != std::string::npos);
    CHECK(problemWith(title, [](Clip &c) {
              TitleContent content;
              content.size = 2.0;
              c.generated = GeneratedContent::makeTitle(content);
          }).find("Size must be a number") != std::string::npos);
    CHECK(problemWith(matte, [](Clip &c) { c.generated = GeneratedContent::makeMatte(SRGBColour{0, 2, 0}); })
              .find("matte's colour") != std::string::npos);
    // Still rules: never reversed, speed 1, sourceIn 0.
    CHECK(problemWith(title, [](Clip &c) { c.reversed = true; }).find("cannot be reversed") != std::string::npos);
    CHECK(problemWith(title, [](Clip &c) { c.speed = Ratio{2, 1}; }).find("speed 1") != std::string::npos);
    // A clip of media carries no content.
    const ClipId media = fx.addClip(fx.v1, fx.av30, 200, 30);
    fx.requireValid();
    CHECK(problemWith(media, [](Clip &c) { c.generated = GeneratedContent::makeMatte(kBlack); })
              .find("a clip of media has no generated content") != std::string::npos);
    // Only video tracks take them (a still has no sound).
    GeneratedFixture audio;
    audio.addGenerated(audio.a1, audio.titles, GeneratedContent::makeTitle(TitleContent{}), 0, 30);
    CHECK(problemOf(audio.project).find("still asset on a audio track") != std::string::npos);
}
