#include "ProjectJSON.h"

#include "../Model/Validation.h"

#include <cstdint>
#include <limits>
#include <utility>
#include <vector>

namespace ve {

using nlohmann::json;

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

json videoParamsToJson(const VideoParams &v) {
    return json{
        {"x", v.x}, {"y", v.y}, {"scale", v.scale}, {"rotationDegrees", v.rotationDegrees}, {"opacity", v.opacity}};
}

json audioParamsToJson(const AudioParams &a) {
    return json{{"gainDb", a.gainDb},
                {"fadeInDuration", timeToJson(a.fadeInDuration)},
                {"fadeOutDuration", timeToJson(a.fadeOutDuration)}};
}

json assetToJson(const MediaAsset &asset) {
    return json{{"id", idToJson(asset.id)},
                {"name", asset.name},
                {"url", asset.url},
                {"kind", nameOf(asset.kind)},
                {"duration", timeToJson(asset.duration)},
                {"width", asset.width},
                {"height", asset.height},
                {"frameDuration", timeToJson(asset.frameDuration)},
                {"isVFR", asset.isVFR},
                {"rotationDegrees", asset.rotationDegrees},
                {"audioSampleRate", asset.audioSampleRate},
                {"audioChannels", asset.audioChannels},
                {"backendHint", asset.backendHint},
                {"hardwareDecode", asset.hardwareDecode}};
}

json clipToJson(const Clip &clip) {
    return json{{"id", idToJson(clip.id)},
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

json transitionToJson(const Transition &transition) {
    return json{{"id", idToJson(transition.id)},
                {"trackId", idToJson(transition.trackId)},
                {"kind", nameOf(transition.kind)},
                {"fromClipId", idToJson(transition.fromClipId)},
                {"toClipId", idToJson(transition.toClipId)},
                {"duration", timeToJson(transition.duration)}};
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
    json transitions = json::array();
    for (const Transition &transition : sequence.transitions) {
        transitions.push_back(transitionToJson(transition));
    }
    return json{{"id", idToJson(sequence.id)},
                {"name", sequence.name},
                {"frameDuration", timeToJson(sequence.frameDuration)},
                {"width", sequence.width},
                {"height", sequence.height},
                {"audioSampleRate", sequence.audioSampleRate},
                {"videoTracks", std::move(videoTracks)},
                {"audioTracks", std::move(audioTracks)},
                {"transitions", std::move(transitions)}};
}

// ----- Reading -----

struct ParseError {
    std::string message;
};

// A JSON value plus its path for error messages.
class Node {
  public:
    Node(const json &value, std::string path) : value_(value), path_(std::move(path)) {}

    const json &value() const {
        return value_;
    }
    const std::string &path() const {
        return path_;
    }

    [[noreturn]] void fail(const std::string &message) const {
        throw ParseError{(path_.empty() ? std::string("(root)") : path_) + ": " + message};
    }

    void requireObject() const {
        if (!value_.is_object()) {
            fail(std::string("expected an object, found ") + value_.type_name());
        }
    }

    bool has(const char *key) const {
        return value_.is_object() && value_.contains(key) && !value_.at(key).is_null();
    }

    Node field(const char *key) const {
        requireObject();
        const auto it = value_.find(key);
        const std::string childPath = path_.empty() ? std::string(key) : path_ + "." + key;
        if (it == value_.end()) {
            throw ParseError{childPath + ": missing required field"};
        }
        return Node(*it, childPath);
    }

    Node element(std::size_t index) const {
        return Node(value_.at(index), path_ + "[" + std::to_string(index) + "]");
    }

    std::size_t arraySize() const {
        if (!value_.is_array()) {
            fail(std::string("expected an array, found ") + value_.type_name());
        }
        return value_.size();
    }

    std::string asString() const {
        if (!value_.is_string()) {
            fail(std::string("expected a string, found ") + value_.type_name());
        }
        return value_.get<std::string>();
    }

    bool asBool() const {
        if (!value_.is_boolean()) {
            fail(std::string("expected a boolean, found ") + value_.type_name());
        }
        return value_.get<bool>();
    }

    double asDouble() const {
        if (!value_.is_number()) {
            fail(std::string("expected a number, found ") + value_.type_name());
        }
        return value_.get<double>();
    }

    std::int64_t asInt64() const {
        if (value_.is_number_unsigned()) {
            const auto v = value_.get<std::uint64_t>();
            if (v > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
                fail("integer out of range");
            }
            return static_cast<std::int64_t>(v);
        }
        if (!value_.is_number_integer()) {
            fail(std::string("expected an integer, found ") + value_.type_name());
        }
        return value_.get<std::int64_t>();
    }

    std::int32_t asInt32() const {
        const std::int64_t v = asInt64();
        if (v < std::numeric_limits<std::int32_t>::min() || v > std::numeric_limits<std::int32_t>::max()) {
            fail("integer out of 32-bit range");
        }
        return static_cast<std::int32_t>(v);
    }

    std::uint64_t asUInt64() const {
        if (value_.is_number_unsigned()) {
            return value_.get<std::uint64_t>();
        }
        if (value_.is_number_integer() && value_.get<std::int64_t>() >= 0) {
            return static_cast<std::uint64_t>(value_.get<std::int64_t>());
        }
        fail(std::string("expected a non-negative integer, found ") + value_.dump());
    }

    template <class IdType> IdType asId() const {
        return IdType{asUInt64()};
    }

    CMTime asTime() const {
        if (value_.is_null()) {
            return kCMTimeInvalid;
        }
        if (!value_.is_object()) {
            fail(std::string("expected a time {value, timescale} or null, found ") + value_.type_name());
        }
        CMTime time;
        time.value = field("value").asInt64();
        time.timescale = field("timescale").asInt32();
        time.flags = kCMTimeFlags_Valid;
        time.epoch = 0;
        if (has("flags")) {
            const std::int64_t flags = field("flags").asInt64();
            if (flags < 0 || flags > 0xFF || (flags & kCMTimeFlags_Valid) == 0) {
                fail("invalid time flags " + std::to_string(flags));
            }
            time.flags = static_cast<CMTimeFlags>(flags);
        }
        if (has("epoch")) {
            time.epoch = field("epoch").asInt64();
        }
        if (CMTIME_IS_NUMERIC(time) && time.timescale <= 0) {
            fail("timescale must be positive");
        }
        return time;
    }

    // Optional-field helpers: absent or null -> fallback.
    std::string stringOr(const char *key, std::string fallback) const {
        return has(key) ? field(key).asString() : std::move(fallback);
    }
    bool boolOr(const char *key, bool fallback) const {
        return has(key) ? field(key).asBool() : fallback;
    }
    double doubleOr(const char *key, double fallback) const {
        return has(key) ? field(key).asDouble() : fallback;
    }
    std::int32_t int32Or(const char *key, std::int32_t fallback) const {
        return has(key) ? field(key).asInt32() : fallback;
    }
    CMTime timeOr(const char *key, CMTime fallback) const {
        if (!value_.is_object() || !value_.contains(key)) {
            return fallback;
        }
        return field(key).asTime();
    }

  private:
    const json &value_;
    std::string path_;
};

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

// Transition kinds are not critical: an unknown one (from a newer version) becomes a cross
// dissolve so the rest of the file still loads.
TransitionKind parseTransitionKind(const Node &node, Warnings &warnings) {
    const std::string s = node.asString();
    if (s == nameOf(TransitionKind::CrossDissolve)) {
        return TransitionKind::CrossDissolve;
    }
    warnings.push_back(node.path() + ": unknown transition kind \"" + s + "\"; using a cross dissolve");
    return TransitionKind::CrossDissolve;
}

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
    asset.rotationDegrees = node.int32Or("rotationDegrees", 0);
    asset.audioSampleRate = node.int32Or("audioSampleRate", 0);
    asset.audioChannels = node.int32Or("audioChannels", 0);
    asset.backendHint = node.stringOr("backendHint", "");
    asset.hardwareDecode = node.boolOr("hardwareDecode", false);
    return asset;
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
    a.fadeInDuration = node.timeOr("fadeInDuration", a.fadeInDuration);
    a.fadeOutDuration = node.timeOr("fadeOutDuration", a.fadeOutDuration);
    return a;
}

Clip parseClip(const Node &node) {
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
    if (node.has("linkedClipId")) {
        clip.linkedClipId = node.field("linkedClipId").asId<ClipId>();
    }
    if (node.has("video")) {
        clip.video = parseVideoParams(node.field("video"));
    }
    if (node.has("audio")) {
        clip.audio = parseAudioParams(node.field("audio"));
    }
    return clip;
}

Track parseTrack(const Node &node) {
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
            track.clips.push_back(parseClip(clips.element(i)));
        }
    }
    return track;
}

Transition parseTransition(const Node &node, Warnings &warnings) {
    node.requireObject();
    Transition transition;
    transition.id = node.field("id").asId<TransitionId>();
    transition.trackId = node.field("trackId").asId<TrackId>();
    transition.kind = parseTransitionKind(node.field("kind"), warnings);
    transition.fromClipId = node.field("fromClipId").asId<ClipId>();
    transition.toClipId = node.field("toClipId").asId<ClipId>();
    transition.duration = node.field("duration").asTime();
    return transition;
}

Sequence parseSequence(const Node &node, Warnings &warnings) {
    node.requireObject();
    Sequence sequence;
    sequence.id = node.field("id").asId<SequenceId>();
    sequence.name = node.stringOr("name", "");
    sequence.frameDuration = node.field("frameDuration").asTime();
    sequence.width = node.field("width").asInt32();
    sequence.height = node.field("height").asInt32();
    sequence.audioSampleRate = node.int32Or("audioSampleRate", 48000);
    for (const char *key : {"videoTracks", "audioTracks"}) {
        if (!node.has(key)) {
            continue;
        }
        const Node list = node.field(key);
        std::vector<Track> &tracks = std::string(key) == "videoTracks" ? sequence.videoTracks : sequence.audioTracks;
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            tracks.push_back(parseTrack(list.element(i)));
        }
    }
    if (node.has("transitions")) {
        const Node list = node.field("transitions");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            sequence.transitions.push_back(parseTransition(list.element(i), warnings));
        }
    }
    return sequence;
}

// ----- Migrations -----

// A stored time with the artefacts of the version 1 time math removed: the rounded flag is
// dropped (the value is kept as exact) and the epoch reset. Records a warning when it changes.
CMTime cleanedTime(CMTime t, const std::string &path, Warnings &warnings) {
    if (!CMTIME_IS_NUMERIC(t) || (!isRounded(t) && t.epoch == 0)) {
        return t;
    }
    warnings.push_back(path + ": " + describe(t) + " was stored rounded or with an epoch; adopted as exact");
    t.flags &= ~kCMTimeFlags_HasBeenRounded;
    t.epoch = 0;
    return t;
}

void cleanTimeField(json &object, const Node &node, const char *key, Warnings &warnings) {
    if (!node.has(key)) {
        return;
    }
    const Node field = node.field(key);
    const CMTime before = field.asTime();
    const CMTime after = cleanedTime(before, field.path(), warnings);
    if (!identical(before, after)) {
        object[key] = timeToJson(after);
    }
}

// Version 1 stored clips as sourceIn/sourceOut/double speed and allowed overlapping fades.
void migrateClipV1(json &clip, const Node &node, CMTime frameDuration, Warnings &warnings) {
    node.requireObject();
    const bool isStill = node.boolOr("isStill", false);
    const double speedValue = node.doubleOr("speed", 1.0);
    // Version 1 applied a double speed as its best ratio with a denominator <= 1000.
    const Ratio speed = isStill ? Ratio{1, 1} : approximateRatio(speedValue, kMaxSpeedDenominator);
    if (!isStill && !isValidSpeed(speed)) {
        node.field("speed").fail("speed " + std::to_string(speedValue) + " is outside [0.01, 100]");
    }
    cleanTimeField(clip, node, "timelineStart", warnings);
    cleanTimeField(clip, node, "sourceIn", warnings);
    const Node inNode = node.field("sourceIn");
    const Node outNode = node.field("sourceOut");
    const auto in = ExactTime::from(inNode.asTime());
    const auto out = ExactTime::from(outNode.asTime());
    if (!in) {
        inNode.fail("expected a numeric time");
    }
    if (!out) {
        outNode.fail("expected a numeric time");
    }
    const auto sourceLength = out->minus(*in);
    const auto exactDuration = sourceLength ? sourceLength->dividedBy(speed) : std::nullopt;
    if (!exactDuration) {
        outNode.fail("the clip's duration overflows exact arithmetic");
    }
    // Version 1 kept the end on the frame grid, but its rounded source out points could leave
    // the exact duration a few nanoseconds off it: snap back when within a microsecond.
    CMTime duration = kCMTimeInvalid;
    const auto frames = isPositive(frameDuration) ? exactDuration->frameIndex(frameDuration, SnapMode::Round)
                                                  : std::nullopt;
    if (frames) {
        const auto snapped = checkedTimeForFrame(*frames, frameDuration);
        const auto snappedExact = snapped ? ExactTime::from(*snapped) : std::nullopt;
        const auto error = snappedExact ? exactDuration->minus(*snappedExact) : std::nullopt;
        const auto tolerance = ExactTime::fraction(1, 1000000);
        if (error && tolerance && error->compare(*tolerance) <= 0 && error->negated().compare(*tolerance) <= 0) {
            duration = *snapped;
            if (error->numerator() != 0) {
                warnings.push_back(outNode.path() + ": the clip's duration was " + describe(exactDuration->toTimeRounded()) +
                                   ", off the frame grid by rounding; snapped to " + describe(duration));
            }
        }
    }
    if (!isNumeric(duration)) {
        const auto exact = exactDuration->toTime();
        if (!exact) {
            outNode.fail("the clip's duration has no exact time form");
        }
        duration = *exact; // validation reports it if it is off the frame grid
    }
    clip.erase("sourceOut");
    clip["duration"] = timeToJson(duration);
    clip["speed"] = json{{"num", speed.num}, {"den", speed.den}};

    if (!node.has("audio") || !node.field("audio").value().is_object()) {
        return;
    }
    json &audio = clip["audio"];
    const Node audioNode = node.field("audio");
    cleanTimeField(audio, audioNode, "fadeInDuration", warnings);
    cleanTimeField(audio, audioNode, "fadeOutDuration", warnings);
    const Node refreshed(audio, audioNode.path());
    const CMTime fadeIn = refreshed.timeOr("fadeInDuration", kCMTimeZero);
    const CMTime fadeOut = refreshed.timeOr("fadeOutDuration", kCMTimeZero);
    const auto fadeInExact = ExactTime::from(fadeIn);
    const auto fadeOutExact = ExactTime::from(fadeOut);
    const auto total = fadeInExact && fadeOutExact ? fadeInExact->plus(*fadeOutExact) : std::nullopt;
    if (total && total->compare(duration) > 0) {
        // Version 1 allowed the fades to overlap; the fade-out gives way.
        Clip fitted;
        fitted.timelineDuration = duration;
        fitted.audio.fadeInDuration = fadeIn;
        fitted.audio.fadeOutDuration = fadeOut;
        fitted.fitFades(ClipEdge::Tail);
        warnings.push_back(audioNode.path() + ": fade-in " + describe(fadeIn) + " and fade-out " + describe(fadeOut) +
                           " overlapped; now " + describe(fitted.audio.fadeInDuration) + " and " +
                           describe(fitted.audio.fadeOutDuration));
        audio["fadeInDuration"] = timeToJson(fitted.audio.fadeInDuration);
        audio["fadeOutDuration"] = timeToJson(fitted.audio.fadeOutDuration);
    }
}

void migrateV1ToV2(json &document, Warnings &warnings) {
    const Node root(document, "");
    root.requireObject();
    if (root.has("assets")) {
        const Node list = root.field("assets");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            const Node asset = list.element(i);
            asset.requireObject();
            for (const char *key : {"duration", "frameDuration"}) {
                if (asset.has(key)) {
                    const Node field = asset.field(key);
                    const CMTime before = field.asTime();
                    const CMTime after = canonicalProbedTime(before);
                    if (!identical(before, after)) {
                        warnings.push_back(field.path() + ": " + describe(before) + " adopted as exact");
                        document["assets"][i][key] = timeToJson(after);
                    }
                }
            }
        }
    }
    if (!root.has("sequences")) {
        return;
    }
    const Node sequences = root.field("sequences");
    for (std::size_t s = 0, sn = sequences.arraySize(); s < sn; ++s) {
        json &sequenceJson = document["sequences"][s];
        const Node sequence(sequenceJson, sequences.element(s).path());
        sequence.requireObject();
        cleanTimeField(sequenceJson, sequence, "frameDuration", warnings);
        const CMTime frameDuration = Node(sequenceJson, sequence.path()).timeOr("frameDuration", kCMTimeInvalid);
        for (const char *key : {"videoTracks", "audioTracks"}) {
            if (!sequence.has(key)) {
                continue;
            }
            const Node tracks = sequence.field(key);
            for (std::size_t t = 0, tn = tracks.arraySize(); t < tn; ++t) {
                const Node track = tracks.element(t);
                track.requireObject();
                if (!track.has("clips")) {
                    continue;
                }
                const Node clips = track.field("clips");
                for (std::size_t c = 0, cn = clips.arraySize(); c < cn; ++c) {
                    json &clipJson = sequenceJson[key][t]["clips"][c];
                    migrateClipV1(clipJson, Node(clipJson, clips.element(c).path()), frameDuration, warnings);
                }
            }
        }
        if (sequence.has("transitions")) {
            const Node transitions = sequence.field("transitions");
            for (std::size_t i = 0, n = transitions.arraySize(); i < n; ++i) {
                json &transitionJson = sequenceJson["transitions"][i];
                const Node transition(transitionJson, transitions.element(i).path());
                transition.requireObject();
                cleanTimeField(transitionJson, transition, "duration", warnings);
            }
        }
    }
}

struct MigrationStep {
    int fromVersion;
    void (*apply)(json &document, Warnings &warnings);
};

// One entry per schema version bump, in order: entry i upgrades fromVersion to fromVersion + 1.
constexpr MigrationStep kMigrations[] = {
    {1, migrateV1ToV2},
};
static_assert(sizeof(kMigrations) / sizeof(kMigrations[0]) == kProjectSchemaVersion - 1,
              "every schema version below the current one needs a migration step");

void runMigrations(json &document, int fromVersion, Warnings &warnings) {
    for (const MigrationStep &step : kMigrations) {
        if (step.fromVersion >= fromVersion) {
            step.apply(document, warnings);
            document["schemaVersion"] = step.fromVersion + 1;
        }
    }
}

Project parseProjectNode(const Node &root, Warnings &warnings) {
    root.requireObject();
    Project project;
    project.name = root.stringOr("name", "");
    if (root.has("assets")) {
        const Node list = root.field("assets");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            project.assets.push_back(parseAsset(list.element(i)));
        }
    }
    if (root.has("sequences")) {
        const Node list = root.field("sequences");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            project.sequences.push_back(parseSequence(list.element(i), warnings));
        }
    }
    if (root.has("activeSequenceId")) {
        project.activeSequenceId = root.field("activeSequenceId").asId<SequenceId>();
    }
    project.ids = IdGenerator(root.field("nextId").asUInt64());
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
    json assets = json::array();
    for (const MediaAsset &asset : project.assets) {
        assets.push_back(assetToJson(asset));
    }
    json sequences = json::array();
    for (const Sequence &sequence : project.sequences) {
        sequences.push_back(sequenceToJson(sequence));
    }
    return json{{"schemaVersion", kProjectSchemaVersion},
                {"name", project.name},
                {"nextId", idToJson(project.ids.nextValue())},
                {"activeSequenceId", idToJson(project.activeSequenceId)},
                {"assets", std::move(assets)},
                {"sequences", std::move(sequences)}};
}

std::string serializeProject(const Project &project, int indent) {
    return projectToJson(project).dump(indent, ' ', false, json::error_handler_t::replace);
}

std::optional<std::string> migrateProjectJson(json &document, int fromVersion, std::vector<std::string> &warnings) {
    if (fromVersion < 1 || fromVersion > kProjectSchemaVersion) {
        return "cannot migrate from schema version " + std::to_string(fromVersion);
    }
    try {
        runMigrations(document, fromVersion, warnings);
    } catch (const ParseError &e) {
        return e.message;
    } catch (const json::exception &e) {
        return std::string("malformed project: ") + e.what();
    }
    return std::nullopt;
}

ProjectLoadResult projectFromJson(const json &document) {
    ProjectLoadResult result;
    try {
        const int version = schemaVersionOf(Node(document, ""));
        Warnings warnings;
        Project project;
        if (version < kProjectSchemaVersion) {
            json upgraded = document;
            runMigrations(upgraded, version, warnings);
            project = parseProjectNode(Node(upgraded, ""), warnings);
        } else {
            project = parseProjectNode(Node(document, ""), warnings);
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
