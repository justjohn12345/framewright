// The transition descriptor tables (Transition.h; grading decision, section 8): the kind table that
// names the six kinds and says which track, mask and parameters each has, the parameter table, the
// static values a transition span sets (TransitionParameters), their project file forms
// (TransitionValueJSON.h, ProjectJSON.h), validation, the audio repair and the kind change.

#include "../../Engine/Serialize/TransitionValueJSON.h"
#include "ModelFixtures.h"

#include <string>
#include <vector>

using namespace vetest;
using nlohmann::json;

namespace {

bool contains(const std::string &haystack, const std::string &needle) {
    return haystack.find(needle) != std::string::npos;
}

// Two touching av30 clips on V1 with a 12-frame Wipe Left around their cut (8 frames before it), linked
// audio under the first with a 10-frame fade out, and a still on V2 with an Iris fade in.
struct ParameterFixture {
    Fixture fx;
    ClipId outgoing;
    ClipId incoming;
    ClipId audio;
    ClipId still;
    SpanId wipe;
    SpanId audioFade;
    SpanId iris;

    ParameterFixture() {
        const auto [v, a] = fx.addLinkedPair(0, 60, 30);
        outgoing = v;
        audio = a;
        incoming = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
        wipe = fx.addTailTransition(outgoing, 8, 4);
        fx.sequence().findTransition(wipe)->kind = TransitionKind::WipeLeft;
        audioFade = fx.addFade(audio, ClipEdge::Tail, f30(10));
        still = fx.addClip(fx.v2, fx.still, 100, 150);
        iris = fx.addFade(still, ClipEdge::Head, f30(12));
        fx.sequence().findTransition(iris)->kind = TransitionKind::Iris;
        fx.requireValid();
    }

    TransitionSpan &span(SpanId id) {
        TransitionSpan *found = fx.sequence().findTransition(id);
        REQUIRE(found != nullptr);
        return *found;
    }

    // The JSON object of the transition `id` in `document` (the file lists a clip's transitions first).
    static json &spanJson(json &document, const char *tracks, std::size_t track, std::size_t clip) {
        json &spans = document["sequences"][0][tracks][track]["clips"][clip]["spans"];
        REQUIRE(spans.is_array());
        REQUIRE(spans[0]["kind"] == "transition");
        return spans[0];
    }
};

ProjectLoadResult loadOk(const json &document) {
    ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    return loaded;
}

constexpr const char *kCurveChoices[] = {"linear", "equalPower", "exponential"};

// Rows of the value types no parameter has yet (the forms are the table's, ready for them).
TransitionParameterInfo rowOf(TransitionParameterType type) {
    switch (type) {
    case TransitionParameterType::Scalar:
        return infoOf(TransitionParameter::Softness);
    case TransitionParameterType::Angle:
        return {TransitionParameter::Softness, "angle", "Angle", type, TransitionValue::scalar(0.0), -360.0, 360.0, {}};
    case TransitionParameterType::Point:
        return {TransitionParameter::Softness, "centre", "Centre", type, TransitionValue::point(0.5, 0.5), 0.0, 1.0, {}};
    case TransitionParameterType::Colour:
        return {TransitionParameter::Softness, "colour",  "Colour", type, TransitionValue::colour(0.0, 0.0, 0.0, 1.0),
                0.0, 1.0, {}};
    case TransitionParameterType::Enum:
        return {TransitionParameter::Softness, "curve", "Curve", type, TransitionValue::choice(1), 0.0, 0.0,
                kCurveChoices};
    }
    return infoOf(TransitionParameter::Softness);
}

// The ParseError transitionValueFromJson throws for `value`, or "" when it does not throw.
std::string parseFailure(const TransitionParameterInfo &info, const json &value) {
    try {
        (void)serialize::transitionValueFromJson(info, serialize::Node(value, "spans[0].parameters.x"));
    } catch (const serialize::ParseError &error) {
        return error.message;
    }
    return {};
}

} // namespace

TEST_CASE("Transition kinds: one descriptor table names them and says where each fits") {
    struct Row {
        TransitionKind kind;
        const char *name;
        const char *displayName;
        TransitionMask mask;
    };
    // The names the project file and the messages used before the table.
    const std::vector<Row> rows = {
        {TransitionKind::CrossDissolve, "crossDissolve", "Cross Dissolve", TransitionMask::None},
        {TransitionKind::WipeLeft, "wipeLeft", "Wipe Left", TransitionMask::Linear},
        {TransitionKind::WipeRight, "wipeRight", "Wipe Right", TransitionMask::Linear},
        {TransitionKind::WipeUp, "wipeUp", "Wipe Up", TransitionMask::Linear},
        {TransitionKind::WipeDown, "wipeDown", "Wipe Down", TransitionMask::Linear},
        {TransitionKind::Iris, "iris", "Iris", TransitionMask::Radial},
    };
    REQUIRE(rows.size() == kTransitionKinds.size());
    for (std::size_t i = 0; i < rows.size(); ++i) {
        const Row &row = rows[i];
        CAPTURE(row.name);
        CHECK(kTransitionKinds[i] == row.kind);
        const TransitionKindInfo &info = infoOf(row.kind);
        CHECK(info.kind == row.kind);
        CHECK(std::string(nameOf(row.kind)) == row.name);
        CHECK(std::string(displayNameOf(row.kind)) == row.displayName);
        CHECK(transitionKindNamed(row.name) == row.kind);
        CHECK(info.mask == row.mask);
        const bool dissolve = row.kind == TransitionKind::CrossDissolve;
        CHECK(isShapedTransition(row.kind) == !dissolve);
        // Audio has the crossfade only: the cross dissolve fits either track, the shapes video.
        CHECK(transitionKindFitsTrack(row.kind, TrackKind::Video));
        CHECK(transitionKindFitsTrack(row.kind, TrackKind::Audio) == dissolve);
        // The shapes have a soft edge; the uniform mix has no parameter.
        CHECK(transitionKindHasParameter(row.kind, TransitionParameter::Softness) == !dissolve);
        CHECK(info.parameters.size() == (dissolve ? 0u : 1u));
    }
    CHECK_FALSE(transitionKindNamed("wipe").has_value());
    CHECK_FALSE(transitionKindNamed("").has_value());
    CHECK_FALSE(transitionKindNamed("Cross Dissolve").has_value());
    // A value outside the enum (never made by the engine) is named as before the table.
    const auto outside = static_cast<TransitionKind>(42);
    CHECK(std::string(nameOf(outside)) == "unknown");
    CHECK(std::string(displayNameOf(outside)) == "Unknown");
    CHECK(infoOf(outside).kind == TransitionKind::CrossDissolve);
}

TEST_CASE("Transition parameters: the table and valid values") {
    const TransitionParameterInfo &softness = infoOf(TransitionParameter::Softness);
    CHECK(softness.parameter == TransitionParameter::Softness);
    CHECK(std::string(nameOf(TransitionParameter::Softness)) == "softness");
    CHECK(std::string(displayNameOf(TransitionParameter::Softness)) == "Edge Softness");
    CHECK(transitionParameterNamed("softness") == TransitionParameter::Softness);
    CHECK_FALSE(transitionParameterNamed("Softness").has_value());
    CHECK_FALSE(transitionParameterNamed("angle").has_value());
    CHECK(softness.type == TransitionParameterType::Scalar);
    // The default is the soft edge every shaped transition had before the parameter.
    CHECK(softness.defaultValue == TransitionValue::scalar(2.0));
    CHECK(kDefaultTransitionSoftness == 2.0);
    CHECK(softness.choices.empty());

    CHECK(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::scalar(0.0))); // a hard edge
    CHECK(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::scalar(12.5)));
    CHECK(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::scalar(1000.0)));
    CHECK_FALSE(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::scalar(-0.5)));
    CHECK_FALSE(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::scalar(1000.5)));
    CHECK_FALSE(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::scalar(std::nan(""))));
    CHECK_FALSE(isValidTransitionValue(TransitionParameter::Softness,
                                       TransitionValue::scalar(std::numeric_limits<double>::infinity())));
    // A component the type does not use is 0, so equal values compare equal.
    CHECK_FALSE(isValidTransitionValue(TransitionParameter::Softness, TransitionValue::point(4.0, 1.0)));
}

TEST_CASE("Transition parameters: every value type's validity and project file form") {
    SUBCASE("angle: a number of degrees within its range") {
        const TransitionParameterInfo row = rowOf(TransitionParameterType::Angle);
        CHECK(isValidTransitionValue(row, TransitionValue::scalar(-90.0)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::scalar(361.0)));
        CHECK(serialize::transitionValueToJson(row, TransitionValue::scalar(-22.5)) == json(-22.5));
        CHECK(serialize::transitionValueFromJson(row, serialize::Node(json(45), "a")) == TransitionValue::scalar(45.0));
        CHECK(parseFailure(row, json("45")) == "spans[0].parameters.x: expected a number, found string");
    }
    SUBCASE("point: [x, y], each within the range") {
        const TransitionParameterInfo row = rowOf(TransitionParameterType::Point);
        CHECK(isValidTransitionValue(row, TransitionValue::point(0.25, 1.0)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::point(0.25, 1.5)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::point(-0.1, 0.5)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::colour(0.5, 0.5, 0.5, 0.0)));
        const json form = serialize::transitionValueToJson(row, TransitionValue::point(0.25, 0.75));
        CHECK(form == json::array({0.25, 0.75}));
        CHECK(serialize::transitionValueFromJson(row, serialize::Node(form, "p")) == TransitionValue::point(0.25, 0.75));
        CHECK(parseFailure(row, json::array({0.5})) == "spans[0].parameters.x: expected an array of 2 numbers, found 1");
        CHECK(parseFailure(row, json::array({0.5, "a"})) == "spans[0].parameters.x[1]: expected a number, found string");
        CHECK(parseFailure(row, json(0.5)) == "spans[0].parameters.x: expected an array, found number");
    }
    SUBCASE("colour: [r, g, b, a], each 0...1") {
        const TransitionParameterInfo row = rowOf(TransitionParameterType::Colour);
        CHECK(isValidTransitionValue(row, TransitionValue::colour(1.0, 0.5, 0.0, 1.0)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::colour(1.0, 0.5, 0.0, 1.25)));
        const json form = serialize::transitionValueToJson(row, TransitionValue::colour(1.0, 0.5, 0.0, 0.75));
        CHECK(form == json::array({1.0, 0.5, 0.0, 0.75}));
        CHECK(serialize::transitionValueFromJson(row, serialize::Node(form, "c")) ==
              TransitionValue::colour(1.0, 0.5, 0.0, 0.75));
        CHECK(parseFailure(row, json::array({1, 0, 0, 1, 0})) ==
              "spans[0].parameters.x: expected an array of 4 numbers, found 5");
    }
    SUBCASE("enum: the name of one of its choices") {
        const TransitionParameterInfo row = rowOf(TransitionParameterType::Enum);
        CHECK(isValidTransitionValue(row, TransitionValue::choice(0)));
        CHECK(isValidTransitionValue(row, TransitionValue::choice(2)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::choice(3)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::scalar(0.5))); // not an index
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::scalar(-1.0)));
        CHECK_FALSE(isValidTransitionValue(row, TransitionValue::scalar(std::nan(""))));
        CHECK(serialize::transitionValueToJson(row, TransitionValue::choice(2)) == json("exponential"));
        CHECK(serialize::transitionValueFromJson(row, serialize::Node(json("equalPower"), "e")) ==
              TransitionValue::choice(1));
        // A choice this version does not know (a newer version's): the parser keeps it as foreign content.
        CHECK_FALSE(serialize::transitionValueFromJson(row, serialize::Node(json("logarithmic"), "e")).has_value());
        CHECK(parseFailure(row, json(1)) == "spans[0].parameters.x: expected a string, found number");
        // An index outside the choices is never valid; written, it does not throw.
        CHECK(serialize::transitionValueToJson(row, TransitionValue::choice(7)) == json(7.0));
    }
    SUBCASE("scalar: softness") {
        const TransitionParameterInfo &row = infoOf(TransitionParameter::Softness);
        CHECK(serialize::transitionValueToJson(row, TransitionValue::scalar(3.25)) == json(3.25));
        CHECK(serialize::transitionValueFromJson(row, serialize::Node(json(0), "s")) == TransitionValue::scalar(0.0));
        CHECK(parseFailure(row, json::array({1.0})) == "spans[0].parameters.x: expected a number, found array");
    }
}

TEST_CASE("Transition parameters on a span: defaults, what a kind keeps, problems") {
    TransitionParameters parameters;
    CHECK(parameters.empty());
    CHECK(parameters.valueOf(TransitionParameter::Softness) == TransitionValue::scalar(kDefaultTransitionSoftness));
    parameters[TransitionParameter::Softness] = TransitionValue::scalar(6.0);
    CHECK_FALSE(parameters.empty());
    CHECK(parameters.valueOf(TransitionParameter::Softness) == TransitionValue::scalar(6.0));
    // Set to the default, it stays set (the file writes back what it read).
    TransitionParameters atDefault;
    atDefault[TransitionParameter::Softness] = TransitionValue::scalar(kDefaultTransitionSoftness);
    CHECK_FALSE(atDefault.empty());
    CHECK_FALSE(atDefault == TransitionParameters{});

    CHECK_FALSE(transitionParametersProblem(TransitionKind::WipeUp, parameters).has_value());
    CHECK_FALSE(transitionParametersProblem(TransitionKind::Iris, parameters).has_value());
    CHECK_FALSE(transitionParametersProblem(TransitionKind::CrossDissolve, TransitionParameters{}).has_value());
    CHECK(transitionParametersProblem(TransitionKind::CrossDissolve, parameters) ==
          std::optional<std::string>("a Cross Dissolve has no Edge Softness"));
    TransitionParameters negative;
    negative[TransitionParameter::Softness] = TransitionValue::scalar(-1.0);
    CHECK(transitionParametersProblem(TransitionKind::WipeLeft, negative) ==
          std::optional<std::string>("its Edge Softness has the invalid value -1.000000"));

    CHECK(parametersKeptBy(TransitionKind::Iris, parameters) == parameters);
    CHECK(parametersKeptBy(TransitionKind::CrossDissolve, parameters).empty());
    CHECK(parametersKeptBy(TransitionKind::WipeDown, TransitionParameters{}).empty());
}

TEST_CASE("ProjectJSON: a transition's parameters round trip, and old files stay as they were") {
    ParameterFixture p;
    SUBCASE("none set: no \"parameters\" key, so files without parameters read and write unchanged") {
        const json document = projectToJson(p.fx.project);
        json copy = document;
        CHECK_FALSE(ParameterFixture::spanJson(copy, "videoTracks", 0, 0).contains("parameters"));
        const ProjectLoadResult loaded = loadOk(document);
        CHECK(loaded.warnings.empty());
        CHECK(*loaded.project == p.fx.project);
        CHECK(projectToJson(*loaded.project) == document);
    }
    SUBCASE("set: written under \"parameters\" by name and read back bit for bit") {
        p.span(p.wipe).parameters[TransitionParameter::Softness] = TransitionValue::scalar(7.25);
        p.span(p.iris).parameters[TransitionParameter::Softness] = TransitionValue::scalar(kDefaultTransitionSoftness);
        p.fx.requireValid();
        json document = projectToJson(p.fx.project);
        CHECK(ParameterFixture::spanJson(document, "videoTracks", 0, 0)["parameters"] == json{{"softness", 7.25}});
        CHECK(ParameterFixture::spanJson(document, "videoTracks", 1, 0)["parameters"] == json{{"softness", 2.0}});
        const std::string text = serializeProject(p.fx.project);
        const ProjectLoadResult loaded = parseProject(text);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        CHECK(loaded.warnings.empty());
        CHECK(*loaded.project == p.fx.project);
        CHECK(serializeProject(*loaded.project) == text);
    }
    SUBCASE("unknown names are kept with a warning and written back beside the known ones") {
        json document = projectToJson(p.fx.project);
        ParameterFixture::spanJson(document, "videoTracks", 0, 0)["parameters"] =
            json{{"softness", 4.0}, {"border", json{{"width", 3}, {"colour", json::array({1, 0, 0, 1})}}}};
        const ProjectLoadResult loaded = loadOk(document);
        REQUIRE(loaded.warnings.size() == 1);
        CHECK(contains(loaded.warnings[0], "parameters.border: unknown transition parameter \"border\""));
        CHECK(contains(loaded.warnings[0], "kept as it is and saved with the project"));
        const TransitionSpan &span = *loaded.project->sequences[0].findTransition(p.wipe);
        CHECK(span.parameters.valueOf(TransitionParameter::Softness) == TransitionValue::scalar(4.0));
        CHECK(span.foreignParameters == R"({"border":{"colour":[1,0,0,1],"width":3}})");
        CHECK(span.foreignFields.empty());
        CHECK(projectToJson(*loaded.project) == document);
    }
    SUBCASE("a kind this version does not know keeps all of its parameters as they are, without warnings") {
        json document = projectToJson(p.fx.project);
        json &span = ParameterFixture::spanJson(document, "videoTracks", 0, 0);
        span["transition"] = "clockWipe";
        span["parameters"] = json{{"softness", 4.0}, {"startAngle", 90}};
        const ProjectLoadResult loaded = loadOk(document);
        REQUIRE(loaded.warnings.size() == 1); // the kind's
        CHECK(contains(loaded.warnings[0], "unknown transition kind \"clockWipe\""));
        const TransitionSpan &read = *loaded.project->sequences[0].findTransition(p.wipe);
        CHECK(read.kind == TransitionKind::CrossDissolve);
        CHECK(read.parameters.empty()); // a cross dissolve has no softness: it is the unknown kind's
        CHECK(read.foreignParameters == R"({"softness":4.0,"startAngle":90})");
        CHECK(projectToJson(*loaded.project) == document);
    }
    SUBCASE("a value of the wrong shape refuses the file, naming its path") {
        json document = projectToJson(p.fx.project);
        ParameterFixture::spanJson(document, "videoTracks", 0, 0)["parameters"] = json{{"softness", "soft"}};
        const ProjectLoadResult loaded = projectFromJson(document);
        REQUIRE_FALSE(loaded.ok());
        CHECK(contains(loaded.error, "spans[0].parameters.softness: expected a number, found string"));
        ParameterFixture::spanJson(document, "videoTracks", 0, 0)["parameters"] = json::array({4.0});
        const ProjectLoadResult notAnObject = projectFromJson(document);
        REQUIRE_FALSE(notAnObject.ok());
        CHECK(contains(notAnObject.error, "spans[0].parameters: expected an object, found array"));
    }
    SUBCASE("validation refuses a value out of range, or a parameter the kind does not have") {
        json document = projectToJson(p.fx.project);
        ParameterFixture::spanJson(document, "videoTracks", 0, 0)["parameters"] = json{{"softness", -3}};
        const ProjectLoadResult negative = projectFromJson(document);
        REQUIRE_FALSE(negative.ok());
        CHECK(contains(negative.error, "its Edge Softness has the invalid value -3.000000"));
        json dissolve = projectToJson(p.fx.project);
        json &span = ParameterFixture::spanJson(dissolve, "videoTracks", 0, 0);
        span["transition"] = "crossDissolve";
        span["parameters"] = json{{"softness", 3}};
        const ProjectLoadResult refused = projectFromJson(dissolve);
        REQUIRE_FALSE(refused.ok());
        CHECK(contains(refused.error, "a Cross Dissolve has no Edge Softness"));

        Project invalid = p.fx.project;
        invalid.sequences[0].findTransition(p.wipe)->parameters[TransitionParameter::Softness] =
            TransitionValue::scalar(1001.0);
        CHECK(contains(validateProject(invalid).value_or(""), "its Edge Softness has the invalid value 1001.000000"));
    }
    SUBCASE("a shaped kind on audio becomes a cross dissolve without the parameters it does not have") {
        json document = projectToJson(p.fx.project);
        json &fade = ParameterFixture::spanJson(document, "audioTracks", 0, 0);
        fade["transition"] = "wipeRight";
        fade["parameters"] = json{{"softness", 5}, {"border", 2}};
        const ProjectLoadResult loaded = loadOk(document);
        REQUIRE(loaded.warnings.size() == 2);
        CHECK(contains(loaded.warnings[0], "unknown transition parameter \"border\""));
        CHECK(contains(loaded.warnings[1], "an audio transition is a crossfade or a fade, not \"wipeRight\"; using a "
                                           "cross dissolve (without its Edge Softness)"));
        const TransitionSpan &read = *loaded.project->sequences[0].findTransition(p.audioFade);
        CHECK(read.kind == TransitionKind::CrossDissolve);
        CHECK(read.parameters.empty());
        CHECK(read.foreignParameters == R"({"border":2})"); // never makes the file invalid: kept
        Project expected = p.fx.project;
        expected.sequences[0].findTransition(p.audioFade)->foreignParameters = R"({"border":2})";
        CHECK(*loaded.project == expected);
    }
}

TEST_CASE("SetTransitionKind keeps the parameters the new kind has and drops the rest") {
    ParameterFixture p;
    p.span(p.wipe).parameters[TransitionParameter::Softness] = TransitionValue::scalar(9.0);
    p.span(p.wipe).foreignParameters = R"({"border":2})";
    p.fx.requireValid();
    const SequenceId seq = p.fx.project.sequences[0].id;
    SUBCASE("the same kind changes nothing, foreign parameters included") {
        const Project before = p.fx.project;
        SetTransitionKind same(seq, p.wipe, TransitionKind::WipeLeft);
        REQUIRE(same.apply(p.fx.project).ok());
        CHECK(p.fx.project == before);
    }
    SUBCASE("another shape keeps the softness; the foreign parameters described the old kind") {
        SetTransitionKind iris(seq, p.wipe, TransitionKind::Iris);
        applyReversible(p.fx.project, iris);
        const TransitionSpan &span = p.span(p.wipe);
        CHECK(span.kind == TransitionKind::Iris);
        CHECK(span.parameters.valueOf(TransitionParameter::Softness) == TransitionValue::scalar(9.0));
        CHECK(span.foreignParameters.empty());
        p.fx.requireValid();
    }
    SUBCASE("a cross dissolve has no softness") {
        SetTransitionKind dissolve(seq, p.wipe, TransitionKind::CrossDissolve);
        applyReversible(p.fx.project, dissolve);
        CHECK(p.span(p.wipe).parameters.empty());
        CHECK(p.span(p.wipe).foreignParameters.empty());
        p.fx.requireValid();
        // Back to a wipe: the default softness (what was dropped is gone; undo brings it back).
        SetTransitionKind wipe(seq, p.wipe, TransitionKind::WipeLeft);
        applyReversible(p.fx.project, wipe);
        CHECK(p.span(p.wipe).parameters.empty());
        CHECK(p.span(p.wipe).parameters.valueOf(TransitionParameter::Softness) ==
              TransitionValue::scalar(kDefaultTransitionSoftness));
    }
    SUBCASE("a kind chosen for a newer version's kind drops that kind's parameters") {
        TransitionSpan &span = p.span(p.wipe);
        span.kind = TransitionKind::CrossDissolve;
        span.unknownKindName = "clockWipe";
        span.parameters = {};
        span.foreignParameters = R"({"startAngle":90})";
        p.fx.requireValid();
        SetTransitionKind chosen(seq, p.wipe, TransitionKind::CrossDissolve);
        applyReversible(p.fx.project, chosen);
        CHECK(p.span(p.wipe).unknownKindName.empty());
        CHECK(p.span(p.wipe).foreignParameters.empty());
    }
    SUBCASE("an audio transition is refused a shape and keeps what it has") {
        TransitionSpan &fade = p.span(p.audioFade);
        fade.foreignParameters = R"({"curve":"exponential"})";
        const Project before = p.fx.project;
        SetTransitionKind wipe(seq, p.audioFade, TransitionKind::WipeUp);
        const EditResult refused = wipe.apply(p.fx.project);
        CHECK(refused.error == EditError::TrackKindMismatch);
        CHECK(p.fx.project == before);
        SetTransitionKind dissolve(seq, p.audioFade, TransitionKind::CrossDissolve);
        REQUIRE(dissolve.apply(p.fx.project).ok());
        CHECK(p.fx.project == before);
    }
}
