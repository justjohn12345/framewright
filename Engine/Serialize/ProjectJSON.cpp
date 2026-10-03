#include "ProjectJSON.h"

#include "JsonNode.h"
#include "ProjectMigrations.h"
#include "TransitionValueJSON.h"

#include "../Model/Validation.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cstdint>
#include <cstring>
#include <set>
#include <cstdio>
#include <type_traits>
#include <limits>
#include <map>
#include <utility>
#include <variant>
#include <vector>

namespace ve {

using nlohmann::json;
using serialize::Node;
using serialize::ParseError;

static_assert(serialize::kLastMigrationTarget == kProjectSchemaVersion,
              "every schema version below the current one needs a migration step (ProjectMigrations.cpp)");

namespace {

// ----- Writing -----

json idToJson(std::uint64_t value) {
    return value;
}

template <class Tag> json idToJson(Id<Tag> id) {
    return id.value();
}

json optionalIdToJson(const std::optional<ClipId> &id) {
    return id ? json(id->value()) : json(nullptr);
}

json keyframeToJson(const Keyframe &k) {
    json j{{"time", timeToJson(k.time)}, {"value", k.value}, {"interpolation", nameOf(k.interpolation)}};
    if (k.interpolation == KeyframeInterpolation::Bezier) {
        j["curve"] = json::array({k.curve.x1, k.curve.y1, k.curve.x2, k.curve.y2});
    }
    return j;
}

json videoParamsToJson(const VideoParams &v) {
    return json{{"x", v.x}, {"y", v.y}, {"scale", v.scale}, {"rotationDegrees", v.rotationDegrees}, {"opacity", v.opacity}};
}

json audioParamsToJson(const AudioParams &a) {
    return json{{"gainDb", a.gainDb}};
}

json keyframeTrackToJson(const KeyframeTrack &track) {
    json list = json::array();
    for (const Keyframe &keyframe : track) {
        list.push_back(keyframeToJson(keyframe));
    }
    return list;
}

// Compact JSON text kept on the model (ForeignSpanContent) as an object; an empty one for "" (and
// for text that is not an object, which the parser never stores).
json foreignObject(const std::string &text) {
    if (text.empty()) {
        return json::object();
    }
    json value = json::parse(text, nullptr, /*allow_exceptions=*/false);
    return value.is_object() ? value : json::object();
}

// Adds the keys of `extra` that `into` does not have.
void addForeignKeys(json &into, const json &extra) {
    for (const auto &entry : extra.items()) {
        if (!into.contains(entry.key())) {
            into[entry.key()] = entry.value();
        }
    }
}

json spanToJson(const TransitionSpan &span) {
    json j{{"id", idToJson(span.id)},
           {"lane", TransitionSpan::lane},
           {"kind", nameOf(SpanKind::Transition)},
           {"start", timeToJson(span.start)},
           {"end", timeToJson(span.end)},
           {"edge", nameOf(span.edge)},
           {"transition", span.unknownKindName.empty() ? std::string(nameOf(span.kind)) : span.unknownKindName}};
    // The parameters it sets, and the entries of the file's "parameters" this version does not read.
    json parameters = json::object();
    for (const TransitionParameter parameter : kTransitionParameters) {
        if (const auto &value = span.parameters[parameter]) {
            parameters[nameOf(parameter)] = serialize::transitionValueToJson(infoOf(parameter), *value);
        }
    }
    addForeignKeys(parameters, foreignObject(span.foreignParameters));
    if (!parameters.empty()) {
        j["parameters"] = std::move(parameters);
    }
    // What a newer version wrote that this one does not read goes back as it came (review core #9).
    addForeignKeys(j, foreignObject(span.foreignFields));
    return j;
}

json spanToJson(const EffectSpan &span) {
    json j{{"id", idToJson(span.id)},
           {"lane", span.lane},
           {"kind", span.isUnknownKind() ? span.foreign.kindName : std::string(nameOf(span.kind))},
           {"start", timeToJson(span.start)},
           {"end", timeToJson(span.end)}};
    // What a newer version wrote that this one does not read goes back as it came (review core #9).
    addForeignKeys(j, foreignObject(span.foreign.fields));
    if (span.isUnknownKind()) {
        return j;
    }
    json tracks = json::object();
    for (const SpanParameter parameter : kSpanParameters) {
        const KeyframeTrack &track = span.tracks.track(parameter);
        if (!track.empty()) {
            tracks[nameOf(parameter)] = keyframeTrackToJson(track);
        }
    }
    // Foreign tracks only while their keyframes still lie within the span (ForeignSpanContent).
    const auto length = checkedSubtract(span.end, span.start);
    if (!span.foreign.tracks.empty() && length && CMTIME_IS_NUMERIC(span.foreign.tracksLength) &&
        *length == span.foreign.tracksLength) {
        addForeignKeys(tracks, foreignObject(span.foreign.tracks));
    }
    j["tracks"] = std::move(tracks);
    return j;
}

json assetToJson(const MediaAsset &asset) {
    json j{{"id", idToJson(asset.id)},
                {"name", asset.name},
                {"url", asset.url},
                {"kind", nameOf(asset.kind)},
                {"duration", timeToJson(asset.duration)},
                {"width", asset.width},
                {"height", asset.height},
                {"frameDuration", timeToJson(asset.frameDuration)},
                {"isVFR", asset.isVFR},
                {"videoDuration", timeToJson(asset.videoDuration)},
                {"rotationDegrees", asset.rotationDegrees},
                {"audioSampleRate", asset.audioSampleRate},
                {"audioChannels", asset.audioChannels},
                {"backendHint", asset.backendHint},
                {"hardwareDecode", asset.hardwareDecode}};
    // Schema 10: a generator asset says what it generates (a file asset writes what version 9 wrote).
    if (asset.isGenerator()) {
        j["generator"] = nameOf(asset.generator);
    }
    return j;
}

// MARK: Titles and colour mattes (schema 10; point text and the anchor, schema 11)

json colourToJson(const SRGBColour &colour) {
    return json::array({colour.red, colour.green, colour.blue});
}

json titleFontToJson(const TitleFont &font) {
    if (font.isSystem) {
        return json{{"system", nameOf(font.weight)}};
    }
    return json{{"name", font.postScriptName}, {"family", font.family}, {"style", font.style}};
}

json titleValueToJson(const TitleValue &value) {
    return std::visit(
        [](const auto &v) -> json {
            using V = std::decay_t<decltype(v)>;
            if constexpr (std::is_same_v<V, TitleFont>) {
                return titleFontToJson(v);
            } else if constexpr (std::is_same_v<V, SRGBColour>) {
                return colourToJson(v);
            } else if constexpr (std::is_same_v<V, TitleAlignment> || std::is_same_v<V, TitleAnchor>) {
                return nameOf(v);
            } else {
                return json(v);
            }
        },
        value);
}

// A generated clip's "generated": {"kind": "title", every parameter of the title by its table name} or
// {"kind": "colourMatte", "colour"}, then the entries this version does not read as they came. Every parameter
// is written (not only those that differ from the defaults), so a later change of a default never changes
// what a saved title looks like.
json generatedToJson(const GeneratedContent &content) {
    json j{{"kind", nameOf(content.kind())}};
    if (content.isTitle()) {
        for (const TitleParameter parameter : kTitleParameters) {
            j[nameOf(parameter)] = titleValueToJson(valueOf(content.title(), parameter));
        }
    } else {
        j["colour"] = colourToJson(content.matteColour());
    }
    addForeignKeys(j, foreignObject(content.foreign()));
    return j;
}

// A clip's grade: the values that are not neutral, then the entries this version does not read (a
// newer version's parameters) as they came. Written only when not empty (ClipGrade::isEmpty), so a
// clip without a grade writes what version 7 wrote.
// The colour wheels (slice 2) are flat keys of a number each, "<wheel>Level", "<wheel>Cb", "<wheel>Cr"
// ("liftLevel", "gammaCr", ...), written when not zero; the curves are "curveLuma", "curveRed", ... each a
// list of [x, y] points, written when not the identity. Flat keys, so a version that does not know them keeps
// them as foreign entries.
json gradeToJson(const ClipGrade &grade) {
    json j = json::object();
    for (const GradeParameter parameter : kGradeParameters) {
        if (grade[parameter] != neutralValue(parameter)) {
            j[nameOf(parameter)] = grade[parameter];
        }
    }
    for (const GradeWheel wheel : kGradeWheels) {
        const WheelValue &value = grade[wheel];
        const std::string name = nameOf(wheel);
        if (value.level != 0.0) {
            j[name + "Level"] = value.level;
        }
        if (value.cb != 0.0) {
            j[name + "Cb"] = value.cb;
        }
        if (value.cr != 0.0) {
            j[name + "Cr"] = value.cr;
        }
    }
    if (!grade.inputLut.empty()) {
        j["inputLut"] = grade.inputLut;
    }
    if (!grade.lookLut.empty()) {
        j["lookLut"] = grade.lookLut;
        if (grade.lookStrength != 1.0) {
            j["lookStrength"] = grade.lookStrength;
        }
    }
    const auto pointsToJson = [](const CurvePoints &points) {
        json list = json::array();
        for (const CurvePoint &point : points) {
            list.push_back(json::array({point.x, point.y}));
        }
        return list;
    };
    for (const GradeCurve curve : kGradeCurves) {
        if (!grade[curve].empty()) {
            j[nameOf(curve)] = pointsToJson(grade[curve]);
        }
    }
    for (const GradeHueCurve curve : kGradeHueCurves) {
        if (!grade[curve].empty()) {
            j[nameOf(curve)] = pointsToJson(grade[curve]);
        }
    }
    addForeignKeys(j, foreignObject(grade.foreign));
    return j;
}

// MARK: LUTs (schema 9)

static_assert(std::endian::native == std::endian::little, "the LUT data is written as little-endian float32");

constexpr char kBase64Alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64Encode(const unsigned char *bytes, std::size_t length) {
    std::string out;
    out.reserve((length + 2) / 3 * 4);
    for (std::size_t i = 0; i < length; i += 3) {
        const std::uint32_t chunk = (std::uint32_t(bytes[i]) << 16) | (i + 1 < length ? std::uint32_t(bytes[i + 1]) << 8 : 0u) |
                                    (i + 2 < length ? std::uint32_t(bytes[i + 2]) : 0u);
        out.push_back(kBase64Alphabet[(chunk >> 18) & 63]);
        out.push_back(kBase64Alphabet[(chunk >> 12) & 63]);
        out.push_back(i + 1 < length ? kBase64Alphabet[(chunk >> 6) & 63] : '=');
        out.push_back(i + 2 < length ? kBase64Alphabet[chunk & 63] : '=');
    }
    return out;
}

// The bytes of base64 `text`, or nullopt when it is not base64 (padding only at the end).
std::optional<std::vector<unsigned char>> base64Decode(const std::string &text) {
    if (text.size() % 4 != 0) {
        return std::nullopt;
    }
    std::vector<unsigned char> out;
    out.reserve(text.size() / 4 * 3);
    for (std::size_t i = 0; i < text.size(); i += 4) {
        std::uint32_t chunk = 0;
        int padding = 0;
        for (std::size_t k = 0; k < 4; ++k) {
            const char c = text[i + k];
            std::uint32_t value = 0;
            if (c == '=' && i + 4 == text.size() && k >= 2) {
                ++padding;
            } else if (padding > 0) {
                return std::nullopt;
            } else if (const char *at = std::strchr(kBase64Alphabet, c); at != nullptr && c != '\0') {
                value = std::uint32_t(at - kBase64Alphabet);
            } else {
                return std::nullopt;
            }
            chunk = (chunk << 6) | value;
        }
        out.push_back(static_cast<unsigned char>(chunk >> 16));
        if (padding < 2) {
            out.push_back(static_cast<unsigned char>(chunk >> 8));
        }
        if (padding < 1) {
            out.push_back(static_cast<unsigned char>(chunk));
        }
    }
    return out;
}

json floatTriple(const std::array<float, 3> &values) {
    return json::array({values[0], values[1], values[2]});
}

json lutToJson(const std::string &id, const CubeLut &lut) {
    return json{{"id", id},
                {"kind", lut.kind == CubeKind::OneD ? "1d" : "3d"},
                {"size", lut.size},
                {"domainMin", floatTriple(lut.domainMin)},
                {"domainMax", floatTriple(lut.domainMax)},
                {"title", lut.title},
                {"fileName", lut.fileName},
                {"path", lut.sourcePath},
                {"data", base64Encode(reinterpret_cast<const unsigned char *>(lut.table.data()),
                                      lut.table.size() * sizeof(float))}};
}

json clipToJson(const Clip &clip) {
    json j{{"id", idToJson(clip.id)},
                {"assetId", idToJson(clip.assetId)},
                {"trackId", idToJson(clip.trackId)},
                {"timelineStart", timeToJson(clip.timelineStart)},
                {"duration", timeToJson(clip.timelineDuration)},
                {"sourceIn", timeToJson(clip.sourceIn)},
                {"speed", json{{"num", clip.speed.num}, {"den", clip.speed.den}}},
                {"isStill", clip.isStill},
                {"linkedClipId", optionalIdToJson(clip.linkedClipId)},
                {"video", videoParamsToJson(clip.video)},
                {"audio", audioParamsToJson(clip.audio)}};
    if (clip.reversed) {
        j["reversed"] = true;
    }
    if (!clip.grade.isEmpty()) {
        j["grade"] = gradeToJson(clip.grade);
    }
    if (clip.generated) {
        j["generated"] = generatedToJson(*clip.generated);
    }
    if (!clip.transitions.empty() || !clip.spans.empty()) {
        // One list in the file: lane 0 (the transitions, head then tail), then lanes 1-3.
        json spans = json::array();
        for (const TransitionSpan &span : clip.transitions) {
            spans.push_back(spanToJson(span));
        }
        for (const EffectSpan &span : clip.spans) {
            spans.push_back(spanToJson(span));
        }
        j["spans"] = std::move(spans);
    }
    return j;
}

json trackToJson(const Track &track) {
    json clips = json::array();
    for (const Clip &clip : track.clips) {
        clips.push_back(clipToJson(clip));
    }
    return json{{"id", idToJson(track.id)}, {"kind", nameOf(track.kind)}, {"name", track.name},
                {"muted", track.muted},     {"solo", track.solo},         {"locked", track.locked},
                {"clips", std::move(clips)}};
}

json sequenceToJson(const Sequence &sequence) {
    json videoTracks = json::array();
    for (const Track &track : sequence.videoTracks) {
        videoTracks.push_back(trackToJson(track));
    }
    json audioTracks = json::array();
    for (const Track &track : sequence.audioTracks) {
        audioTracks.push_back(trackToJson(track));
    }
    return json{{"id", idToJson(sequence.id)},
                {"name", sequence.name},
                {"configured", sequence.configured},
                {"frameDuration", timeToJson(sequence.frameDuration)},
                {"width", sequence.width},
                {"height", sequence.height},
                {"audioSampleRate", sequence.audioSampleRate},
                {"videoTracks", std::move(videoTracks)},
                {"audioTracks", std::move(audioTracks)}};
}

// ----- Reading -----

AssetKind parseAssetKind(const Node &node) {
    const std::string s = node.asString();
    for (const AssetKind kind : {AssetKind::Video, AssetKind::Audio, AssetKind::Still, AssetKind::AudioVideo}) {
        if (s == nameOf(kind)) {
            return kind;
        }
    }
    node.fail("unknown asset kind \"" + s + "\"");
}

TrackKind parseTrackKind(const Node &node) {
    const std::string s = node.asString();
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        if (s == nameOf(kind)) {
            return kind;
        }
    }
    node.fail("unknown track kind \"" + s + "\"");
}

using Warnings = std::vector<std::string>;

MediaAsset parseAsset(const Node &node) {
    node.requireObject();
    MediaAsset asset;
    asset.id = node.field("id").asId<AssetId>();
    asset.name = node.stringOr("name", "");
    asset.url = node.stringOr("url", "");
    asset.kind = parseAssetKind(node.field("kind"));
    asset.duration = node.timeOr("duration", kCMTimeInvalid);
    asset.width = node.int32Or("width", 0);
    asset.height = node.int32Or("height", 0);
    asset.frameDuration = node.timeOr("frameDuration", kCMTimeInvalid);
    asset.isVFR = node.boolOr("isVFR", false);
    asset.videoDuration = node.timeOr("videoDuration", kCMTimeInvalid);
    asset.rotationDegrees = node.int32Or("rotationDegrees", 0);
    asset.audioSampleRate = node.int32Or("audioSampleRate", 0);
    asset.audioChannels = node.int32Or("audioChannels", 0);
    asset.backendHint = node.stringOr("backendHint", "");
    asset.hardwareDecode = node.boolOr("hardwareDecode", false);
    if (node.has("generator")) {
        const Node generator = node.field("generator");
        const std::string name = generator.asString();
        const auto kind = generatorKindNamed(name);
        if (!kind) {
            // Its clips' content could not be drawn, nor kept as a clip of a file: the project cannot open.
            generator.fail("unknown generator kind \"" + name + "\" (from a newer version of Framewright?)");
        }
        asset.generator = *kind;
    }
    return asset;
}

// Interpolations are not critical: an unknown one (from a newer version) becomes linear so the
// rest of the file still loads.
KeyframeInterpolation parseInterpolation(const Node &node, Warnings &warnings) {
    const std::string s = node.asString();
    for (const KeyframeInterpolation interpolation :
         {KeyframeInterpolation::Hold, KeyframeInterpolation::Linear, KeyframeInterpolation::EaseOut,
          KeyframeInterpolation::EaseIn, KeyframeInterpolation::EaseInOut, KeyframeInterpolation::Bezier}) {
        if (s == nameOf(interpolation)) {
            return interpolation;
        }
    }
    warnings.push_back(node.path() + ": unknown keyframe interpolation \"" + s + "\"; using linear");
    return KeyframeInterpolation::Linear;
}

Keyframe parseKeyframe(const Node &node, Warnings &warnings) {
    node.requireObject();
    Keyframe keyframe;
    keyframe.time = node.field("time").asTime();
    keyframe.value = node.field("value").asDouble();
    keyframe.interpolation =
        node.has("interpolation") ? parseInterpolation(node.field("interpolation"), warnings) : KeyframeInterpolation::Linear;
    if (keyframe.interpolation != KeyframeInterpolation::Bezier && node.has("curve")) {
        // Only a custom (Bezier) segment has a curve; the others use their own (validation).
        warnings.push_back(node.path() + ": a timing curve on a " + nameOf(keyframe.interpolation) +
                           " keyframe was ignored");
    }
    if (keyframe.interpolation == KeyframeInterpolation::Bezier) {
        const Node curve = node.field("curve");
        if (curve.arraySize() != 4) {
            curve.fail("expected four numbers [x1, y1, x2, y2]");
        }
        keyframe.curve = TimingCurve{curve.element(0).asDouble(), curve.element(1).asDouble(),
                                     curve.element(2).asDouble(), curve.element(3).asDouble()};
    }
    return keyframe;
}

VideoParams parseVideoParams(const Node &node) {
    node.requireObject();
    VideoParams v;
    v.x = node.doubleOr("x", v.x);
    v.y = node.doubleOr("y", v.y);
    v.scale = node.doubleOr("scale", v.scale);
    v.rotationDegrees = node.doubleOr("rotationDegrees", v.rotationDegrees);
    v.opacity = node.doubleOr("opacity", v.opacity);
    return v;
}

AudioParams parseAudioParams(const Node &node) {
    node.requireObject();
    AudioParams a;
    a.gainDb = node.doubleOr("gainDb", a.gainDb);
    return a;
}

KeyframeTrack parseKeyframeTrack(const Node &list, Warnings &warnings) {
    KeyframeTrack track;
    for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
        track.push_back(parseKeyframe(list.element(i), warnings));
    }
    return track;
}

ClipEdge parseClipEdge(const Node &node) {
    const std::string s = node.asString();
    for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
        if (s == nameOf(edge)) {
            return edge;
        }
    }
    node.fail("unknown clip edge \"" + s + "\"");
}

// The keys of a span's JSON object this version reads, per kind of span; every other key is kept as
// foreign content (TransitionSpan::foreignFields, ForeignSpanContent::fields): those of every span,
// and "edge", "transition" and "parameters" of a transition or "tracks" of a known effect span.
enum class SpanKeys { Transition, Effect, Unknown };
bool isKnownSpanKey(const std::string &key, SpanKeys keys) {
    if (key == "id" || key == "lane" || key == "kind" || key == "start" || key == "end") {
        return true;
    }
    switch (keys) {
    case SpanKeys::Transition:
        return key == "edge" || key == "transition" || key == "parameters";
    case SpanKeys::Effect:
        return key == "tracks";
    case SpanKeys::Unknown:
        break;
    }
    return false;
}

// The keys of `node` this version does not read, as compact JSON text.
std::string unknownSpanKeys(const Node &node, SpanKeys keys);

// Compact JSON text of an object, for ForeignSpanContent ("" for an empty object).
std::string foreignText(const json &object) {
    return object.empty() ? std::string() : object.dump(-1, ' ', false, json::error_handler_t::replace);
}

std::string unknownSpanKeys(const Node &node, SpanKeys keys) {
    json unknownFields = json::object();
    for (const auto &entry : node.value().items()) {
        if (!isKnownSpanKey(entry.key(), keys)) {
            unknownFields[entry.key()] = entry.value();
        }
    }
    return foreignText(unknownFields);
}

// One element of a clip's "spans": a transition (lane 0) or an effect span, and the lane the file
// gave it (a transition's lane is repaired to 0 by repairSequence, with a warning).
struct ParsedSpan {
    std::variant<TransitionSpan, EffectSpan> span;
    int lane = 0;
};

// A transition: its edge and kind. A kind this version does not know (a newer version's) is shown and
// edited as a cross dissolve but kept by name, so saving the project does not rewrite it (review L8).
TransitionSpan parseTransitionSpan(const Node &node, Warnings &warnings) {
    TransitionSpan span;
    span.id = node.field("id").asId<SpanId>();
    span.start = node.field("start").asTime();
    span.end = node.field("end").asTime();
    span.foreignFields = unknownSpanKeys(node, SpanKeys::Transition);
    span.edge = parseClipEdge(node.field("edge"));
    if (node.has("transition")) {
        const Node transitionNode = node.field("transition");
        const std::string name = transitionNode.asString();
        if (const auto known = transitionKindNamed(name)) {
            span.kind = *known;
        } else if (name.empty()) {
            warnings.push_back(transitionNode.path() + ": an empty transition kind; using a cross dissolve");
        } else {
            span.unknownKindName = name;
            warnings.push_back(transitionNode.path() + ": unknown transition kind \"" + name +
                               "\" (from a newer version of Framewright?); shown as a cross dissolve and saved as \"" +
                               name + "\"");
        }
    }
    if (node.has("parameters")) {
        const Node parametersNode = node.field("parameters");
        parametersNode.requireObject();
        json foreign = json::object();
        for (const auto &entry : parametersNode.value().items()) {
            const std::string &key = entry.key();
            const auto parameter = transitionParameterNamed(key);
            if (!span.unknownKindName.empty()) {
                foreign[key] = entry.value(); // a kind this version does not know: all of them are its own
                continue;
            }
            const Node valueNode(entry.value(), parametersNode.path() + "." + key);
            if (!parameter) {
                foreign[key] = entry.value();
                warnings.push_back(valueNode.path() + ": unknown transition parameter \"" + key +
                                   "\" (from a newer version of Framewright?); kept as it is and saved with the "
                                   "project, but not played or editable");
                continue;
            }
            if (const auto value = serialize::transitionValueFromJson(infoOf(*parameter), valueNode)) {
                span.parameters[*parameter] = *value;
            } else {
                foreign[key] = entry.value();
                warnings.push_back(valueNode.path() + ": unknown choice " + entry.value().dump() + " of " +
                                   displayNameOf(*parameter) +
                                   " (from a newer version of Framewright?); kept as it is and saved with the project, "
                                   "and the default played");
            }
        }
        span.foreignParameters = foreignText(foreign);
    }
    return span;
}

// A span of a kind this version does not know (from a newer one) is kept as it is (SpanKind::Unknown)
// when it lies on an effect lane, and so are the unknown keys and parameters of a known span, so
// that saving writes them back (review core #9); each with a warning but the unknown keys (newer
// minor additions, ignored silently before they were kept). An unknown kind on lane 0 (transitions
// only here) cannot be placed: nullopt, with a warning.
std::optional<ParsedSpan> parseSpan(const Node &node, Warnings &warnings) {
    node.requireObject();
    const Node kindNode = node.field("kind");
    const std::string kindName = kindNode.asString();
    const std::optional<SpanKind> kind = spanKindNamed(kindName);
    // The keys every span has, checked in this order: kind, id, lane, start, end.
    const SpanId id = node.field("id").asId<SpanId>();
    const int lane = node.field("lane").asInt32();
    if (kind == SpanKind::Transition) {
        return ParsedSpan{parseTransitionSpan(node, warnings), lane};
    }
    EffectSpan span;
    span.id = id;
    span.kind = kind.value_or(SpanKind::Unknown);
    span.lane = lane;
    span.start = node.field("start").asTime();
    span.end = node.field("end").asTime();
    if (!kind) {
        if (span.lane == kTransitionLane) {
            warnings.push_back(kindNode.path() + ": unknown span kind \"" + kindName +
                               "\" on lane 0, which holds transitions only here; the span was dropped");
            return std::nullopt;
        }
        span.foreign.kindName = kindName;
        warnings.push_back(kindNode.path() + ": unknown span kind \"" + kindName +
                           "\" (from a newer version of Framewright?); kept as it is and saved with the project, "
                           "but not shown, played or editable");
    }
    span.foreign.fields = unknownSpanKeys(node, span.isUnknownKind() ? SpanKeys::Unknown : SpanKeys::Effect);
    if (span.isUnknownKind()) {
        return ParsedSpan{span, lane};
    }
    if (node.has("tracks")) {
        const Node tracks = node.field("tracks");
        tracks.requireObject();
        json unknownTracks = json::object();
        for (const auto &entry : tracks.value().items()) {
            if (!spanParameterNamed(entry.key())) {
                unknownTracks[entry.key()] = entry.value();
                warnings.push_back(tracks.path() + ": unknown span parameter \"" + entry.key() +
                                   "\" (from a newer version of Framewright?); its keyframes are kept as they are "
                                   "and saved with the project, but not played or editable");
            }
        }
        if (!unknownTracks.empty()) {
            // Without an exact length the keyframes could not be kept within the span: validation
            // refuses such a span anyway.
            if (const auto length = checkedSubtract(span.end, span.start)) {
                span.foreign.tracks = foreignText(unknownTracks);
                span.foreign.tracksLength = *length;
            }
        }
        for (const SpanParameter parameter : kSpanParameters) {
            if (tracks.has(nameOf(parameter))) {
                span.tracks.track(parameter) = parseKeyframeTrack(tracks.field(nameOf(parameter)), warnings);
            }
        }
    }
    return ParsedSpan{span, lane};
}

// A clip's "grade": an object of the parameters it sets (GradeParameterInfo::name: a number each; a
// parameter left out is neutral). A value outside its parameter's range is limited to it, with a
// warning; an entry this version does not know (a newer version's parameter) is kept as it is and
// written back on save (ClipGrade::foreign), with a warning. A value that is not a number fails the
// load with its path.
// The wheel key `key` names ("liftLevel" -> Lift, member 0; "gammaCb" -> Gamma, 1; "gainCr" -> Gain, 2).
std::optional<std::pair<GradeWheel, int>> wheelKeyNamed(const std::string &key) {
    static constexpr const char *kMembers[] = {"Level", "Cb", "Cr"};
    for (const GradeWheel wheel : kGradeWheels) {
        const std::string name = nameOf(wheel);
        for (int member = 0; member < 3; ++member) {
            if (key == name + kMembers[member]) {
                return std::make_pair(wheel, member);
            }
        }
    }
    return std::nullopt;
}

ClipGrade parseGrade(const Node &node, Warnings &warnings) {
    node.requireObject();
    ClipGrade grade;
    json foreign = json::object();
    for (const auto &entry : node.value().items()) {
        const std::string &key = entry.key();
        const Node valueNode(entry.value(), node.path() + "." + key);
        if (const auto wheelKey = wheelKeyNamed(key)) {
            WheelValue &value = grade[wheelKey->first];
            double &member = wheelKey->second == 0 ? value.level : wheelKey->second == 1 ? value.cb : value.cr;
            member = valueNode.asDouble(); // a JSON number is finite
            continue;
        }
        if (key == "inputLut" || key == "lookLut") {
            (key == "inputLut" ? grade.inputLut : grade.lookLut) = valueNode.asString();
            continue;
        }
        if (key == "lookStrength") {
            const double strength = valueNode.asDouble();
            grade.lookStrength = std::clamp(strength, 0.0, 1.0);
            if (strength != grade.lookStrength) {
                warnings.push_back(valueNode.path() + ": the look strength " + entry.value().dump() +
                                   " is outside its range [0, 1]; limited to " + json(grade.lookStrength).dump());
            }
            continue;
        }
        const auto readPoints = [&valueNode]() {
            CurvePoints points;
            const std::size_t count = valueNode.arraySize();
            for (std::size_t i = 0; i < count; ++i) {
                const Node pointNode = valueNode.element(i);
                if (pointNode.arraySize() != 2) {
                    pointNode.fail("expected a point [x, y]");
                }
                points.push_back(CurvePoint{pointNode.element(0).asDouble(), pointNode.element(1).asDouble()});
            }
            return points;
        };
        if (const auto hueCurve = gradeHueCurveNamed(key)) {
            const CurvePoints points = readPoints();
            CurvePoints kept = sanitizedHueCurve(points);
            if (const auto problem = hueCurveProblem(points)) {
                warnings.push_back(valueNode.path() + ": the " + displayNameOf(*hueCurve) + " curve's points are not a " +
                                   "valid curve (" + *problem + "); kept " + std::to_string(kept.size()) + " of " +
                                   std::to_string(points.size()) +
                                   (kept.empty() ? " (no curve)" : ", sorted and limited"));
            }
            grade[*hueCurve] = std::move(kept);
            continue;
        }
        if (const auto curve = gradeCurveNamed(key)) {
            const CurvePoints points = readPoints();
            CurvePoints kept = sanitizedCurve(points);
            if (const auto problem = curveProblem(points)) {
                warnings.push_back(valueNode.path() + ": the " + displayNameOf(*curve) + " curve's points are not a " +
                                   "valid curve (" + *problem + "); kept " +
                                   std::to_string(kept.size()) + " of " + std::to_string(points.size()) +
                                   (kept.empty() ? " (no curve)" : ", sorted and limited to [0, 1]"));
            }
            grade[*curve] = std::move(kept);
            continue;
        }
        const auto parameter = gradeParameterNamed(key);
        if (!parameter) {
            foreign[key] = entry.value();
            warnings.push_back(valueNode.path() + ": unknown grade parameter \"" + key +
                               "\" (from a newer version of Framewright?); kept as it is and saved with the project, "
                               "but not applied or editable");
            continue;
        }
        const double value = valueNode.asDouble();
        if (!isValidGradeValue(*parameter, value)) {
            const double limited = clampGradeValue(*parameter, value);
            const GradeParameterInfo &info = infoOf(*parameter);
            warnings.push_back(valueNode.path() + ": " + info.displayName + " " + entry.value().dump() +
                               " is outside its range [" + json(info.minimum).dump() + ", " +
                               json(info.maximum).dump() + "]; limited to " + json(limited).dump());
            grade[*parameter] = limited;
        } else {
            grade[*parameter] = value;
        }
    }
    // A wheel outside its range (a level beyond 1, a colour outside the wheel) is moved into it.
    for (const GradeWheel wheel : kGradeWheels) {
        if (!isValidWheel(grade[wheel])) {
            const WheelValue limited = clampWheel(grade[wheel]);
            const auto text = [](double v) {
                char buffer[32];
                std::snprintf(buffer, sizeof buffer, "%g", v);
                return std::string(buffer);
            };
            warnings.push_back(node.path() + ": the " + displayNameOf(wheel) + " wheel (level " +
                               text(grade[wheel].level) + ", colour " + text(grade[wheel].cb) + ", " +
                               text(grade[wheel].cr) + ") is outside its range; limited to level " + text(limited.level) +
                               ", colour " + text(limited.cb) + ", " + text(limited.cr));
            grade[wheel] = limited;
        }
    }
    grade.foreign = foreignText(foreign);
    return grade;
}

// A colour [r, g, b] (sRGB components); a component outside [0, 1] is limited to it, with a warning.
SRGBColour parseColour(const Node &node, const std::string &what, Warnings &warnings) {
    if (node.arraySize() != 3) {
        node.fail("expected a colour [r, g, b]");
    }
    SRGBColour colour{node.element(0).asDouble(), node.element(1).asDouble(), node.element(2).asDouble()};
    if (!isValidColour(colour)) {
        const SRGBColour limited{std::clamp(colour.red, 0.0, 1.0), std::clamp(colour.green, 0.0, 1.0),
                                 std::clamp(colour.blue, 0.0, 1.0)};
        warnings.push_back(node.path() + ": " + what + " " + node.value().dump() +
                           " has a component outside [0, 1]; limited to " + colourToJson(limited).dump());
        colour = limited;
    }
    return colour;
}

// A title's "font": {"system": weight} or {"name": PostScript name, "family", "style"}. An unknown weight
// (a newer version's) is read as Regular, with a warning.
TitleFont parseTitleFont(const Node &node, Warnings &warnings) {
    node.requireObject();
    if (node.has("system")) {
        const Node weightNode = node.field("system");
        const std::string name = weightNode.asString();
        if (const auto weight = systemFontWeightNamed(name)) {
            return TitleFont::system(*weight);
        }
        warnings.push_back(weightNode.path() + ": unknown weight \"" + name +
                           "\" of the system font (from a newer version of Framewright?); using Regular");
        return TitleFont::system(SystemFontWeight::Regular);
    }
    TitleFont font = TitleFont::named(node.field("name").asString(), node.stringOr("family", ""),
                                      node.stringOr("style", ""));
    if (auto problem = titleValueProblem(TitleParameter::Font, font)) {
        node.fail(*problem);
    }
    return font;
}

// A generated clip's "generated" (generatedToJson): its kind, a title's parameters (a parameter left out
// has its default) or a matte's colour. A number or a colour outside its range is limited to it, an
// unknown alignment or anchor is read as centre, with a warning each; an entry this version does not read (a newer
// version's parameter) is kept as it is and written back on save (GeneratedContent::foreign), with a
// warning. An unknown kind, a value of the wrong JSON type, or a text or font that is not valid fails the
// load with its path.
std::shared_ptr<const GeneratedContent> parseGenerated(const Node &node, Warnings &warnings) {
    node.requireObject();
    const Node kindNode = node.field("kind");
    const std::string kindName = kindNode.asString();
    const auto kind = generatorKindNamed(kindName);
    if (!kind || *kind == GeneratorKind::None) {
        kindNode.fail("unknown generated content kind \"" + kindName + "\" (from a newer version of Framewright?)");
    }
    json foreign = json::object();
    const auto keepForeign = [&](const std::string &key, const json &value, const Node &valueNode) {
        foreign[key] = value;
        warnings.push_back(valueNode.path() + ": unknown " + (*kind == GeneratorKind::Title ? "title" : "matte") +
                           " parameter \"" + key +
                           "\" (from a newer version of Framewright?); kept as it is and saved with the project, "
                           "but not drawn or editable");
    };
    if (*kind == GeneratorKind::ColourMatte) {
        SRGBColour colour = kBlack;
        for (const auto &entry : node.value().items()) {
            const std::string &key = entry.key();
            const Node valueNode(entry.value(), node.path() + "." + key);
            if (key == "kind") {
                continue;
            }
            if (key == "colour") {
                colour = parseColour(valueNode, "the matte's colour", warnings);
                continue;
            }
            keepForeign(key, entry.value(), valueNode);
        }
        return GeneratedContent::makeMatte(colour, foreignText(foreign));
    }
    TitleContent title;
    for (const auto &entry : node.value().items()) {
        const std::string &key = entry.key();
        const Node valueNode(entry.value(), node.path() + "." + key);
        if (key == "kind") {
            continue;
        }
        const auto parameter = titleParameterNamed(key);
        if (!parameter) {
            keepForeign(key, entry.value(), valueNode);
            continue;
        }
        const TitleParameterInfo &info = infoOf(*parameter);
        TitleValue value;
        switch (info.type) {
        case TitleValueType::Text:
            value = valueNode.asString();
            break;
        case TitleValueType::Font:
            value = parseTitleFont(valueNode, warnings);
            break;
        case TitleValueType::Number: {
            const double number = valueNode.asDouble(); // a JSON number is finite
            const double limited = std::clamp(number, info.minimum, info.maximum);
            if (limited != number) {
                warnings.push_back(valueNode.path() + ": " + info.displayName + " " + entry.value().dump() +
                                   " is outside its range [" + json(info.minimum).dump() + ", " +
                                   json(info.maximum).dump() + "]; limited to " + json(limited).dump());
            }
            value = limited;
            break;
        }
        case TitleValueType::Colour:
            value = parseColour(valueNode, std::string("the title's ") + info.displayName, warnings);
            break;
        case TitleValueType::Choice: {
            const std::string name = valueNode.asString();
            const auto alignment = titleAlignmentNamed(name);
            if (!alignment) {
                warnings.push_back(valueNode.path() + ": unknown alignment \"" + name +
                                   "\" (from a newer version of Framewright?); using centre");
            }
            value = alignment.value_or(TitleAlignment::Centre);
            break;
        }
        case TitleValueType::Toggle:
            value = valueNode.asBool();
            break;
        case TitleValueType::Anchor: {
            const std::string name = valueNode.asString();
            const auto anchor = titleAnchorNamed(name);
            if (!anchor) {
                warnings.push_back(valueNode.path() + ": unknown anchor \"" + name +
                                   "\" (from a newer version of Framewright?); using centre");
            }
            value = anchor.value_or(TitleAnchor::Centre);
            break;
        }
        }
        if (auto problem = titleValueProblem(*parameter, value)) {
            valueNode.fail(*problem); // a text too long (JSON strings are UTF-8)
        }
        setValue(title, *parameter, value);
    }
    return GeneratedContent::makeTitle(std::move(title), foreignText(foreign));
}

// The spans of each clip in the order the file lists them (one list there, two containers on the
// model), with the lane the file gave each: repairSequence reports and repairs in that order.
struct FileSpan {
    bool transition = false; // in Clip::transitions (else Clip::spans), in the same order as here
    int lane = 0;
};
using SpanFileOrder = std::map<ClipId, std::vector<FileSpan>>;

Clip parseClip(const Node &node, Warnings &warnings, SpanFileOrder &order) {
    node.requireObject();
    Clip clip;
    clip.id = node.field("id").asId<ClipId>();
    clip.assetId = node.field("assetId").asId<AssetId>();
    clip.trackId = node.field("trackId").asId<TrackId>();
    clip.timelineStart = node.field("timelineStart").asTime();
    clip.timelineDuration = node.field("duration").asTime();
    clip.sourceIn = node.field("sourceIn").asTime();
    if (node.has("speed")) {
        const Node speed = node.field("speed");
        speed.requireObject();
        const std::int64_t num = speed.field("num").asInt64();
        const std::int64_t den = speed.field("den").asInt64();
        if (den <= 0) {
            speed.field("den").fail("speed denominator must be positive");
        }
        clip.speed = Ratio{num, den};
    }
    clip.isStill = node.boolOr("isStill", false);
    clip.reversed = node.boolOr("reversed", false);
    if (node.has("linkedClipId")) {
        clip.linkedClipId = node.field("linkedClipId").asId<ClipId>();
    }
    if (node.has("video")) {
        clip.video = parseVideoParams(node.field("video"));
    }
    if (node.has("audio")) {
        clip.audio = parseAudioParams(node.field("audio"));
    }
    if (node.has("grade")) {
        clip.grade = parseGrade(node.field("grade"), warnings);
    }
    if (node.has("generated")) {
        clip.generated = parseGenerated(node.field("generated"), warnings);
    }
    if (node.has("spans")) {
        const Node spans = node.field("spans");
        std::vector<FileSpan> &listed = order[clip.id];
        for (std::size_t i = 0, n = spans.arraySize(); i < n; ++i) {
            if (auto parsed = parseSpan(spans.element(i), warnings)) {
                if (auto *transition = std::get_if<TransitionSpan>(&parsed->span)) {
                    listed.push_back(FileSpan{true, parsed->lane});
                    clip.transitions.push_back(std::move(*transition));
                } else {
                    listed.push_back(FileSpan{false, parsed->lane});
                    clip.spans.push_back(std::get<EffectSpan>(std::move(parsed->span)));
                }
            }
        }
    }
    return clip;
}

Track parseTrack(const Node &node, Warnings &warnings, SpanFileOrder &order) {
    node.requireObject();
    Track track;
    track.id = node.field("id").asId<TrackId>();
    track.kind = parseTrackKind(node.field("kind"));
    track.name = node.stringOr("name", "");
    track.muted = node.boolOr("muted", false);
    track.solo = node.boolOr("solo", false);
    track.locked = node.boolOr("locked", false);
    if (node.has("clips")) {
        const Node clips = node.field("clips");
        for (std::size_t i = 0, n = clips.arraySize(); i < n; ++i) {
            const Node clipNode = clips.element(i);
            Clip clip = parseClip(clipNode, warnings, order);
            // A grade is for pictures (validateSequence): one on a clip of an audio track is dropped.
            if (track.kind != TrackKind::Video && !clip.grade.isEmpty()) {
                warnings.push_back(clipNode.path() + ".grade: a clip on an audio track has no grade; dropped");
                clip.grade = ClipGrade{};
            }
            track.clips.push_back(std::move(clip));
        }
    }
    return track;
}

Sequence parseSequence(const Node &node, Warnings &warnings, SpanFileOrder &order) {
    node.requireObject();
    Sequence sequence;
    sequence.id = node.field("id").asId<SequenceId>();
    sequence.name = node.stringOr("name", "");
    sequence.frameDuration = node.field("frameDuration").asTime();
    sequence.width = node.field("width").asInt32();
    sequence.height = node.field("height").asInt32();
    sequence.audioSampleRate = node.int32Or("audioSampleRate", 48000);
    // Absent (a hand-written file): configured, so opening it never changes its settings.
    sequence.configured = node.boolOr("configured", true);
    for (const char *key : {"videoTracks", "audioTracks"}) {
        if (!node.has(key)) {
            continue;
        }
        const Node list = node.field(key);
        std::vector<Track> &tracks = std::string(key) == "videoTracks" ? sequence.videoTracks : sequence.audioTracks;
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            tracks.push_back(parseTrack(list.element(i), warnings, order));
        }
    }
    return sequence;
}

// A LUT of the file's "luts" and the id the file gives it. A malformed entry fails the load with its path (the
// table is the LUT: nothing could stand in for it).
std::pair<std::string, CubeLut> parseLut(const Node &node) {
    node.requireObject();
    CubeLut lut;
    const std::string id = node.field("id").asString();
    const std::string kind = node.field("kind").asString();
    if (kind != "1d" && kind != "3d") {
        node.field("kind").fail("expected \"1d\" or \"3d\"");
    }
    lut.kind = kind == "1d" ? CubeKind::OneD : CubeKind::ThreeD;
    const std::uint64_t size = node.field("size").asUInt64();
    const std::uint32_t limit = lut.kind == CubeKind::OneD ? kMaxCube1DSize : kMaxCube3DSize;
    if (size < 2 || size > limit) {
        node.field("size").fail("must be from 2 to " + std::to_string(limit));
    }
    lut.size = std::uint32_t(size);
    for (const char *key : {"domainMin", "domainMax"}) {
        const Node triple = node.field(key);
        if (triple.arraySize() != 3) {
            triple.fail("expected [r, g, b]");
        }
        std::array<float, 3> &target = std::string(key) == "domainMin" ? lut.domainMin : lut.domainMax;
        for (std::size_t c = 0; c < 3; ++c) {
            target[c] = float(triple.element(c).asDouble());
        }
    }
    lut.title = node.stringOr("title", "");
    lut.fileName = node.stringOr("fileName", "");
    lut.sourcePath = node.stringOr("path", "");
    const Node data = node.field("data");
    const auto bytes = base64Decode(data.asString());
    if (!bytes || bytes->size() != lut.entryCount() * 3 * sizeof(float)) {
        data.fail("expected the base64 of " + std::to_string(lut.entryCount() * 3) + " float32 values");
    }
    lut.table.resize(lut.entryCount() * 3);
    std::memcpy(lut.table.data(), bytes->data(), bytes->size());
    if (auto problem = cubeProblem(lut)) {
        node.fail(*problem);
    }
    return {id, std::move(lut)};
}

Project parseProjectNode(const Node &root, Warnings &warnings, SpanFileOrder &order) {
    root.requireObject();
    Project project;
    project.name = root.stringOr("name", "");
    if (root.has("assets")) {
        const Node list = root.field("assets");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            project.assets.push_back(parseAsset(list.element(i)));
        }
    }
    // The LUTs, by the id the file gives them, and the ids their contents give (they differ only in a file
    // edited by hand: the clips' references follow the contents).
    std::map<std::string, std::string> lutIds;
    if (root.has("luts")) {
        const Node list = root.field("luts");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            auto [fileId, lut] = parseLut(list.element(i));
            const std::string id = project.addLut(std::move(lut));
            if (id != fileId) {
                warnings.push_back(list.element(i).path() + ": the LUT's id " + fileId +
                                   " does not match its table; kept as " + id);
            }
            lutIds[fileId] = id;
        }
    }
    if (root.has("sequences")) {
        const Node list = root.field("sequences");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            project.sequences.push_back(parseSequence(list.element(i), warnings, order));
        }
    }
    // Each clip's LUTs: a reference to a LUT the file does not hold is dropped (with its look strength). A
    // title or a matte has no grade (section 5 of the titles design; a newer version might allow one): dropped.
    for (Sequence &sequence : project.sequences) {
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (Track &track : sequence.tracks(kind)) {
                for (Clip &clip : track.clips) {
                    if (const MediaAsset *asset = project.findAsset(clip.assetId);
                        asset != nullptr && asset->isGenerator() && !clip.grade.isEmpty()) {
                        warnings.push_back("clip " + std::to_string(clip.id.value()) + ": a " +
                                           displayNameOf(asset->generator) + " clip has no grade; dropped");
                        clip.grade = ClipGrade{};
                    }
                    for (std::string *lut : {&clip.grade.inputLut, &clip.grade.lookLut}) {
                        if (lut->empty()) {
                            continue;
                        }
                        const auto found = lutIds.find(*lut);
                        if (found == lutIds.end()) {
                            warnings.push_back("clip " + std::to_string(clip.id.value()) + ": its grade's LUT " + *lut +
                                               " is not in the project's \"luts\"; dropped");
                            lut->clear();
                        } else {
                            *lut = found->second;
                        }
                    }
                    if (clip.grade.lookLut.empty() && clip.grade.lookStrength != 1.0) {
                        warnings.push_back("clip " + std::to_string(clip.id.value()) +
                                           ": a look strength without a look; dropped");
                        clip.grade.lookStrength = 1.0;
                    }
                }
            }
        }
    }
    if (root.has("activeSequenceId")) {
        project.activeSequenceId = root.field("activeSequenceId").asId<SequenceId>();
    }
    project.ids = IdGenerator(root.field("nextId").asUInt64());
    project.sharpenScaledDownSources = root.boolOr("sharpenScaledDownSources", true);
    return project;
}

// The document's schema version, checked to be one this build can read.
int schemaVersionOf(const Node &root) {
    root.requireObject();
    if (!root.value().contains("schemaVersion")) {
        root.fail("missing \"schemaVersion\"; this is not a Framewright project");
    }
    const Node versionNode = root.field("schemaVersion");
    const std::int64_t version = versionNode.asInt64();
    if (version > kProjectSchemaVersion) {
        versionNode.fail("project uses schema version " + std::to_string(version) +
                         ", newer than this version of Framewright supports (" + std::to_string(kProjectSchemaVersion) +
                         ")");
    }
    if (version < 1) {
        versionNode.fail("invalid schema version " + std::to_string(version));
    }
    return static_cast<int>(version);
}

} // namespace

json timeToJson(CMTime time) {
    if (CMTIME_IS_INVALID(time)) {
        return nullptr;
    }
    json j{{"value", time.value}, {"timescale", time.timescale}};
    if (time.flags != kCMTimeFlags_Valid) {
        j["flags"] = static_cast<std::uint32_t>(time.flags);
    }
    if (time.epoch != 0) {
        j["epoch"] = time.epoch;
    }
    return j;
}

json projectToJson(const Project &project) {
    json sequences = json::array();
    std::set<std::string> usedLuts;
    std::set<AssetId> usedAssets;
    for (const Sequence &sequence : project.sequences) {
        sequences.push_back(sequenceToJson(sequence));
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : sequence.tracks(kind)) {
                for (const Clip &clip : track.clips) {
                    usedAssets.insert(clip.assetId);
                    for (const std::string *lut : {&clip.grade.inputLut, &clip.grade.lookLut}) {
                        if (!lut->empty()) {
                            usedLuts.insert(*lut);
                        }
                    }
                }
            }
        }
    }
    // Every file asset; a generator asset only while a clip uses it (the next title makes it again).
    json assets = json::array();
    for (const MediaAsset &asset : project.assets) {
        if (asset.isFileBacked() || usedAssets.count(asset.id) != 0) {
            assets.push_back(assetToJson(asset));
        }
    }
    json document{{"schemaVersion", kProjectSchemaVersion},
                  {"name", project.name},
                  {"nextId", idToJson(project.ids.nextValue())},
                  {"activeSequenceId", idToJson(project.activeSequenceId)},
                  {"assets", std::move(assets)},
                  {"sequences", std::move(sequences)},
                  {"sharpenScaledDownSources", project.sharpenScaledDownSources}};
    // Only the LUTs a clip uses, in id order (a valid project holds every one of them).
    json luts = json::array();
    for (const std::string &id : usedLuts) {
        if (const CubeLut *lut = project.findLut(id)) {
            luts.push_back(lutToJson(id, *lut));
        }
    }
    if (!luts.empty()) {
        document["luts"] = std::move(luts);
    }
    return document;
}

std::string serializeProject(const Project &project, int indent) {
    return projectToJson(project).dump(indent, ' ', false, json::error_handler_t::replace);
}

std::optional<std::string> migrateProjectJson(json &document, int fromVersion, std::vector<std::string> &warnings) {
    return migrateProjectJson(document, fromVersion, kProjectSchemaVersion, warnings);
}

std::optional<std::string> migrateProjectJson(json &document, int fromVersion, int toVersion,
                                              std::vector<std::string> &warnings) {
    if (fromVersion < 1 || fromVersion > kProjectSchemaVersion) {
        return "cannot migrate from schema version " + std::to_string(fromVersion);
    }
    if (toVersion < fromVersion || toVersion > kProjectSchemaVersion) {
        return "cannot migrate from schema version " + std::to_string(fromVersion) + " to " +
               std::to_string(toVersion);
    }
    try {
        serialize::runProjectMigrations(document, fromVersion, toVersion, warnings);
    } catch (const ParseError &e) {
        return e.message;
    } catch (const json::exception &e) {
        return std::string("malformed project: ") + e.what();
    }
    return std::nullopt;
}

namespace {

// Repairs, with a warning each, what a file may hold that the model forbids but that has one safe
// reading (review M8): clips and spans out of order are sorted; "reversed" on a still is cleared
// (post-lanes review L3: a still has no direction); a transition off lane 0 goes to
// lane 0; an effect span off lanes 1-3, or overlapping an earlier span of its lane, moves to the
// first effect lane where it overlaps nothing (the composition does not depend on the lane: its
// operations commute), refused when no lane has room; transitions that are not valid (a fade in on
// a clip another clip touches, a dissolve whose handles are gone...) are removed as every edit
// removes them. Everything else (an inexact time, overlapping clips, a keyframe without a value...)
// is left to validateProject or the parser, which refuse the file.
std::optional<std::string> repairSequence(Sequence &sequence, const Project &project, const SpanFileOrder &fileOrder,
                                          Warnings &warnings) {
    const std::string where = "sequence " + std::to_string(sequence.id.value());
    // A time that is not an exact model time (rounded, another epoch, not numeric) has no safe
    // reading: nothing is repaired, and validation refuses the file with that time.
    for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                for (const CMTime t : {clip.timelineStart, clip.timelineDuration, clip.sourceIn}) {
                    if (modelTimeProblem(t, "time")) {
                        return std::nullopt;
                    }
                }
                for (const TransitionSpan &span : clip.transitions) {
                    if (modelTimeProblem(span.start, "time") || modelTimeProblem(span.end, "time")) {
                        return std::nullopt;
                    }
                }
                for (const EffectSpan &span : clip.spans) {
                    if (modelTimeProblem(span.start, "time") || modelTimeProblem(span.end, "time")) {
                        return std::nullopt;
                    }
                }
            }
        }
    }
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            const bool clipsInOrder = std::is_sorted(track.clips.begin(), track.clips.end(), [](const Clip &a, const Clip &b) {
                return a.timelineStart < b.timelineStart;
            });
            if (!clipsInOrder) {
                track.sortClips();
                warnings.push_back(where + ": track " + std::to_string(track.id.value()) +
                                   ": its clips were not in time order; sorted");
            }
            for (Clip &clip : track.clips) {
                const std::string clipWhere = where + ": clip " + std::to_string(clip.id.value());
                // "reversed" on a still (review L3): it has no direction, forward is the only reading.
                // (Every other clip's media has a length: validation requires a positive duration of
                // a non-still asset and a clip's still flag to match its asset's.)
                if (clip.reversed && clip.isStill) {
                    clip.reversed = false;
                    warnings.push_back(clipWhere + ": a still has no direction to reverse; \"reversed\" was cleared");
                }
                // A span of an unknown kind (from a newer version) stays only where this version's
                // rules allow an effect span (its lane is repaired below): kept elsewhere, it would
                // make validation refuse the whole file.
                std::vector<bool> dropped(clip.spans.size(), false);
                for (std::size_t i = 0; i < clip.spans.size(); ++i) {
                    const EffectSpan &span = clip.spans[i];
                    if (!span.isUnknownKind()) {
                        continue;
                    }
                    EffectSpan placed = span;
                    placed.lane = kFirstEffectLane;
                    if (const auto problem = effectSpanProblem(placed, clip, track.kind)) {
                        warnings.push_back(clipWhere + ": " + *problem + "; the \"" + span.foreign.kindName +
                                           "\" span from a newer version was dropped");
                        dropped[i] = true;
                    }
                }
                // Lanes, in the file's order (both kinds): a transition lies on lane 0; each effect span
                // keeps its lane unless that is not an effect lane or an earlier span of the lane overlaps it.
                std::vector<const EffectSpan *> placed;
                auto overlapping = [&](const EffectSpan &span, int lane) -> const EffectSpan * {
                    for (const EffectSpan *other : placed) {
                        if (other->lane == lane && span.start < other->end && other->start < span.end) {
                            return other;
                        }
                    }
                    return nullptr;
                };
                std::vector<SpanId> fileIds; // of the spans that stay
                const auto listed = fileOrder.find(clip.id);
                const std::vector<FileSpan> noSpans;
                std::size_t nextTransition = 0;
                std::size_t nextEffect = 0;
                for (const FileSpan &entry : listed != fileOrder.end() ? listed->second : noSpans) {
                    if (entry.transition) {
                        if (nextTransition >= clip.transitions.size()) {
                            continue;
                        }
                        TransitionSpan &transition = clip.transitions[nextTransition++];
                        fileIds.push_back(transition.id);
                        const std::string spanWhere = clipWhere + ": span " + std::to_string(transition.id.value());
                        if (entry.lane != kTransitionLane) {
                            warnings.push_back(spanWhere + ": a transition lies on lane 0, found lane " +
                                               std::to_string(entry.lane) + "; moved to lane 0");
                        }
                        if (!transitionKindFitsTrack(transition.kind, track.kind)) {
                            // The parameters a cross dissolve does not have go with the kind (its foreign
                            // ones stay: they never make the file invalid).
                            const TransitionParameters kept =
                                parametersKeptBy(TransitionKind::CrossDissolve, transition.parameters);
                            std::string droppedParameters;
                            for (const TransitionParameter parameter : kTransitionParameters) {
                                if (transition.parameters[parameter] && !kept[parameter]) {
                                    droppedParameters +=
                                        std::string(droppedParameters.empty() ? "" : ", ") + displayNameOf(parameter);
                                }
                            }
                            const std::string without =
                                droppedParameters.empty() ? "" : " (without its " + droppedParameters + ")";
                            warnings.push_back(spanWhere + ": an audio transition is a crossfade or a fade, not \"" +
                                               nameOf(transition.kind) + "\"; using a cross dissolve" + without);
                            transition.kind = TransitionKind::CrossDissolve;
                            transition.parameters = kept;
                        }
                        continue;
                    }
                    if (nextEffect >= clip.spans.size()) {
                        continue;
                    }
                    const std::size_t index = nextEffect++;
                    if (dropped[index]) {
                        continue;
                    }
                    EffectSpan &span = clip.spans[index];
                    fileIds.push_back(span.id);
                    const std::string spanWhere = clipWhere + ": span " + std::to_string(span.id.value());
                    const bool effectLane = kFirstEffectLane <= span.lane && span.lane <= kLastLane;
                    const EffectSpan *blocker = effectLane ? overlapping(span, span.lane) : nullptr;
                    if (!effectLane || blocker != nullptr) {
                        std::optional<int> free;
                        for (int lane = kFirstEffectLane; lane <= kLastLane && !free; ++lane) {
                            if (overlapping(span, lane) == nullptr) {
                                free = lane;
                            }
                        }
                        const std::string problem =
                            effectLane ? "overlaps span " + std::to_string(blocker->id.value()) + " on lane " +
                                             std::to_string(span.lane)
                                       : "lane " + std::to_string(span.lane) + " is not an effect lane (" +
                                             std::to_string(kFirstEffectLane) + " to " + std::to_string(kLastLane) + ")";
                        if (!free) {
                            return spanWhere + ": " + problem + ", and no effect lane has room for it";
                        }
                        warnings.push_back(spanWhere + ": " + problem + "; moved to lane " + std::to_string(*free));
                        span.lane = *free;
                    }
                    placed.push_back(&span);
                }
                for (std::size_t i = clip.spans.size(); i-- > 0;) {
                    if (dropped[i]) {
                        clip.spans.erase(clip.spans.begin() + static_cast<std::ptrdiff_t>(i));
                    }
                }
                clip.sortSpans();
                // Sorted: lane 0 (head, then tail), then lanes 1-3 by start.
                std::vector<SpanId> sortedIds;
                for (const TransitionSpan &transition : clip.transitions) {
                    sortedIds.push_back(transition.id);
                }
                for (const EffectSpan &span : clip.spans) {
                    sortedIds.push_back(span.id);
                }
                const bool sorted = sortedIds == fileIds;
                if (!sorted) {
                    warnings.push_back(clipWhere + ": its spans were not in lane and time order; sorted");
                }
            }
        }
    }
    std::vector<std::string> removed;
    pruneInvalidTransitions(sequence, project, &removed);
    warnings.insert(warnings.end(), removed.begin(), removed.end());
    return std::nullopt;
}

} // namespace

ProjectLoadResult projectFromJson(const json &document) {
    ProjectLoadResult result;
    try {
        const int version = schemaVersionOf(Node(document, ""));
        Warnings warnings;
        Project project;
        SpanFileOrder spanOrder;
        if (version < kProjectSchemaVersion) {
            json upgraded = document;
            serialize::runProjectMigrations(upgraded, version, kProjectSchemaVersion, warnings);
            project = parseProjectNode(Node(upgraded, ""), warnings, spanOrder);
        } else {
            project = parseProjectNode(Node(document, ""), warnings, spanOrder);
        }
        for (Sequence &sequence : project.sequences) {
            if (auto problem = repairSequence(sequence, project, spanOrder, warnings)) {
                result.error = "invalid project: " + *problem;
                return result;
            }
        }
        if (auto problem = validateProject(project)) {
            result.error = "invalid project: " + *problem;
            return result;
        }
        result.project = std::move(project);
        result.warnings = std::move(warnings);
    } catch (const ParseError &e) {
        result.error = e.message;
    } catch (const json::exception &e) {
        result.error = std::string("malformed project: ") + e.what();
    }
    return result;
}

ProjectLoadResult parseProject(std::string_view text) {
    json document = json::parse(text.begin(), text.end(), nullptr, /*allow_exceptions=*/false);
    if (document.is_discarded()) {
        ProjectLoadResult result;
        // Re-parse with exceptions for a precise message (byte offset and cause).
        try {
            (void)json::parse(text.begin(), text.end());
            result.error = "malformed JSON";
        } catch (const json::parse_error &e) {
            result.error = std::string("malformed JSON: ") + e.what();
        }
        return result;
    }
    return projectFromJson(document);
}

} // namespace ve
