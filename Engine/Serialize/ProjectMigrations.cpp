#include "ProjectMigrations.h"

#include "JsonNode.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <optional>
#include <utility>

// Frozen migration steps: see ProjectMigrations.h. Nothing here may call into Engine/Model (other
// than TimeUtil's exact arithmetic) or into the current parser and writer; each step keeps copies
// of what it used from them when it was frozen (2026-10-01, schema version 7), named after the
// version whose rule they are.

namespace ve::serialize {

using nlohmann::json;

namespace {

using Warnings = std::vector<std::string>;

struct StepContext {
    Warnings &warnings;
    int targetVersion; // the version the project is saved as after loading (warnings name it)
};

// ----- What every version stores alike -----

// A time as versions 1-7 store it: {"value", "timescale"}, "flags" when not plain valid, "epoch"
// when not 0; null for an invalid time.
json timeJson(CMTime time) {
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

// A time in a warning: "value/timescale (seconds s)", " rounded" when it is.
std::string describeTime(CMTime t) {
    if (CMTIME_IS_INVALID(t)) {
        return "invalid";
    }
    if (CMTIME_IS_POSITIVE_INFINITY(t)) {
        return "+infinity";
    }
    if (CMTIME_IS_NEGATIVE_INFINITY(t)) {
        return "-infinity";
    }
    if (CMTIME_IS_INDEFINITE(t)) {
        return "indefinite";
    }
    char buffer[128];
    std::snprintf(buffer, sizeof buffer, "%lld/%d (%.6f s)%s", static_cast<long long>(t.value), t.timescale,
                  CMTimeGetSeconds(t), isRounded(t) ? " rounded" : "");
    return buffer;
}

// ----- The visitor: one walk and one error policy for every step -----
//
// Sequences, their "videoTracks" then "audioTracks", and each track's "clips", walked as the parser
// reads them and with its error policy (JsonNode.h): a list that is not an array, or an element
// that is not an object, fails with its path (the message the parser would give); an absent or null
// list is skipped. Each callback gets the element's JSON, to change in place, and a Node over it.
// Leaf values a step only looks at to decide on a warning are left to the parser to check.

constexpr std::array<const char *, 2> kTrackLists{"videoTracks", "audioTracks"};

template <class Visit> void forEachSequence(json &document, Visit &&visit) {
    const Node root(document, "");
    root.requireObject();
    if (!root.has("sequences")) {
        return;
    }
    const Node list = root.field("sequences");
    for (std::size_t s = 0, n = list.arraySize(); s < n; ++s) {
        json &sequence = document["sequences"][s];
        const Node node(sequence, list.element(s).path());
        node.requireObject();
        visit(sequence, node);
    }
}

// visit(track, node, isVideo, indexAmongTracksOfItsKind)
template <class Visit> void forEachTrack(json &sequence, const Node &node, Visit &&visit) {
    for (const char *key : kTrackLists) {
        if (!node.has(key)) {
            continue;
        }
        const bool video = key == kTrackLists[0];
        const Node list = node.field(key);
        for (std::size_t t = 0, n = list.arraySize(); t < n; ++t) {
            json &track = sequence[key][t];
            const Node trackNode(track, list.element(t).path());
            trackNode.requireObject();
            visit(track, trackNode, video, t);
        }
    }
}

template <class Visit> void forEachClip(json &track, const Node &node, Visit &&visit) {
    if (!node.has("clips")) {
        return;
    }
    const Node list = node.field("clips");
    for (std::size_t c = 0, n = list.arraySize(); c < n; ++c) {
        json &clip = track["clips"][c];
        const Node clipNode(clip, list.element(c).path());
        clipNode.requireObject();
        visit(clip, clipNode);
    }
}

// ===== 1 -> 2 =====

namespace toV2 {

// Version 1 applied a double speed as its best ratio with a denominator <= 1000, within [0.01, 100].
constexpr std::int64_t kMaxSpeedDenominator = 1000;
constexpr Ratio kMinimumSpeed{1, 100};
constexpr Ratio kMaximumSpeed{100, 1};
constexpr Int128 kInt64Max = std::numeric_limits<std::int64_t>::max();

// The best rational approximation of x with a denominator <= maxDenominator (continued fraction
// convergents, then the best semiconvergent within the bound); {0, 1} when x is not a positive
// finite number or too large.
Ratio approximateRatio(double x, std::int64_t maxDenominator) {
    if (!std::isfinite(x) || x <= 0.0 || maxDenominator < 1) {
        return Ratio{0, 1};
    }
    Int128 p0 = 0, q0 = 1, p1 = 1, q1 = 0;
    double v = x;
    for (int i = 0; i < 64; ++i) {
        const double a = std::floor(v);
        if (a > 1e15) {
            break;
        }
        const auto ai = static_cast<Int128>(a);
        const Int128 p2 = ai * p1 + p0;
        const Int128 q2 = ai * q1 + q0;
        if (q2 > maxDenominator || p2 > kInt64Max) {
            if (q1 > 0 && q2 > maxDenominator) {
                const Int128 k = (maxDenominator - q0) / q1;
                const Int128 ps = p0 + k * p1;
                const Int128 qs = q0 + k * q1;
                const double errSemi = std::fabs(static_cast<double>(ps) / static_cast<double>(qs) - x);
                const double errConv = std::fabs(static_cast<double>(p1) / static_cast<double>(q1) - x);
                if (k > 0 && errSemi < errConv && ps <= kInt64Max) {
                    p1 = ps;
                    q1 = qs;
                }
            }
            break;
        }
        p0 = p1;
        q0 = q1;
        p1 = p2;
        q1 = q2;
        const double fraction = v - a;
        if (fraction < 1e-12) {
            break;
        }
        v = 1.0 / fraction;
    }
    if (q1 == 0) {
        return Ratio{0, 1};
    }
    if (p1 == 0) {
        return Ratio{1, maxDenominator};
    }
    return Ratio{static_cast<std::int64_t>(p1), static_cast<std::int64_t>(q1)};
}

bool isValidSpeed(Ratio speed) {
    return speed.isReduced() && speed.num > 0 && speed.den <= kMaxSpeedDenominator && !(speed < kMinimumSpeed) &&
           !(kMaximumSpeed < speed);
}

// A probed time with version 1's rounding artefacts removed (its value is kept as exact).
CMTime canonicalProbedTime(CMTime t) {
    if (!CMTIME_IS_NUMERIC(t)) {
        return CMTIME_IS_INVALID(t) ? kCMTimeInvalid : t;
    }
    t.flags &= ~kCMTimeFlags_HasBeenRounded;
    t.epoch = 0;
    return t;
}

// A stored time with the artefacts of the version 1 time math removed: the rounded flag is
// dropped (the value is kept as exact) and the epoch reset. Records a warning when it changes.
CMTime cleanedTime(CMTime t, const std::string &path, Warnings &warnings) {
    if (!CMTIME_IS_NUMERIC(t) || (!isRounded(t) && t.epoch == 0)) {
        return t;
    }
    warnings.push_back(path + ": " + describeTime(t) + " was stored rounded or with an epoch; adopted as exact");
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
        object[key] = timeJson(after);
    }
}

// Version 1 stored clips as sourceIn/sourceOut/double speed and allowed overlapping fades.
void migrateClip(json &clip, const Node &node, CMTime frameDuration, Warnings &warnings) {
    node.requireObject();
    const bool isStill = node.boolOr("isStill", false);
    const double speedValue = node.doubleOr("speed", 1.0);
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
                warnings.push_back(outNode.path() + ": the clip's duration was " +
                                   describeTime(exactDuration->toTimeRounded()) +
                                   ", off the frame grid by rounding; snapped to " + describeTime(duration));
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
    clip["duration"] = timeJson(duration);
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
        // Version 1 allowed the fades to overlap; the fade-out gives way (each is first limited to
        // the clip; a remainder without an exact CMTime form removes the fade-out).
        const CMTime length = maxTime(duration, kCMTimeZero);
        const CMTime fittedIn = minTime(fadeIn, length);
        const CMTime fittedOut = checkedSubtract(length, fittedIn).value_or(kCMTimeZero);
        warnings.push_back(audioNode.path() + ": fade-in " + describeTime(fadeIn) + " and fade-out " +
                           describeTime(fadeOut) + " overlapped; now " + describeTime(fittedIn) + " and " +
                           describeTime(fittedOut));
        audio["fadeInDuration"] = timeJson(fittedIn);
        audio["fadeOutDuration"] = timeJson(fittedOut);
    }
}

void migrate(json &document, const StepContext &context) {
    Warnings &warnings = context.warnings;
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
                        warnings.push_back(field.path() + ": " + describeTime(before) + " adopted as exact");
                        document["assets"][i][key] = timeJson(after);
                    }
                }
            }
        }
    }
    forEachSequence(document, [&](json &sequence, const Node &node) {
        cleanTimeField(sequence, node, "frameDuration", warnings);
        const CMTime frameDuration = Node(sequence, node.path()).timeOr("frameDuration", kCMTimeInvalid);
        forEachTrack(sequence, node, [&](json &track, const Node &trackNode, bool, std::size_t) {
            forEachClip(track, trackNode,
                        [&](json &clip, const Node &clipNode) { migrateClip(clip, clipNode, frameDuration, warnings); });
        });
        if (node.has("transitions")) {
            const Node transitions = node.field("transitions");
            for (std::size_t i = 0, n = transitions.arraySize(); i < n; ++i) {
                json &transitionJson = sequence["transitions"][i];
                const Node transition(transitionJson, transitions.element(i).path());
                transition.requireObject();
                cleanTimeField(transitionJson, transition, "duration", warnings);
            }
        }
    });
}

} // namespace toV2

// ===== 2 -> 3 =====

namespace toV3 {

// Version 2's names of the asset kinds that have video.
constexpr const char *kVideoKind = "video";
constexpr const char *kAudioVideoKind = "av";

// Version 2 did not record where an asset's video ends. The container's duration is the best the
// file knows (it is what version 2 let video clips use); the decode pool holds the last frame
// should the pictures end earlier.
void migrate(json &document, const StepContext &) {
    const Node root(document, "");
    root.requireObject();
    if (!root.has("assets")) {
        return;
    }
    const Node list = root.field("assets");
    for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
        const Node asset = list.element(i);
        asset.requireObject();
        if (asset.has("videoDuration") || !asset.has("kind") || !asset.has("duration")) {
            continue;
        }
        const std::string kind = asset.field("kind").asString();
        if (kind == kVideoKind || kind == kAudioVideoKind) {
            document["assets"][i]["videoDuration"] = document["assets"][i]["duration"];
        }
    }
}

} // namespace toV3

// ===== 3 -> 4 =====

namespace toV4 {

// Version 4 added Motion keyframes ("keyframes" in a clip's "video" object, absent when a clip has
// none). A version 3 clip has none, so its document is already a valid version 4 document: the
// step changes nothing but the version number.
void migrate(json &document, const StepContext &) {
    Node(document, "").requireObject();
}

} // namespace toV4

// ===== 4 -> 5: effect spans =====

namespace toV5 {

// --- Version 4's keyframes and version 5's keyframe rules ---

enum class Interpolation { Hold, Linear, EaseOut, EaseIn, EaseInOut, Bezier };

constexpr std::array<std::pair<Interpolation, const char *>, 6> kInterpolations{{
    {Interpolation::Hold, "hold"},
    {Interpolation::Linear, "linear"},
    {Interpolation::EaseOut, "easeOut"},
    {Interpolation::EaseIn, "easeIn"},
    {Interpolation::EaseInOut, "easeInOut"},
    {Interpolation::Bezier, "bezier"},
}};

const char *nameOf(Interpolation interpolation) {
    for (const auto &[value, name] : kInterpolations) {
        if (value == interpolation) {
            return name;
        }
    }
    return "linear";
}

// A cubic Bezier timing curve from (0, 0) to (1, 1) (control points (x1, y1) and (x2, y2)).
struct Curve {
    double x1 = 0.0;
    double y1 = 0.0;
    double x2 = 1.0;
    double y2 = 1.0;
};

struct Key {
    CMTime time = kCMTimeZero;
    double value = 0.0;
    Interpolation interpolation = Interpolation::Linear;
    Curve curve;
};

using KeyTrack = std::vector<Key>;

// The time rule of version 5's model: numeric, positive timescale, epoch 0, not rounded.
bool isExactModelTime(CMTime t) {
    return CMTIME_IS_NUMERIC(t) && t.timescale > 0 && t.epoch == 0 && (t.flags & kCMTimeFlags_HasBeenRounded) == 0;
}

struct Point {
    double x = 0.0;
    double y = 0.0;
};

Point lerp(Point a, Point b, double t) {
    return Point{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t};
}

double cubic(double p1, double p2, double t) {
    const double u = 1.0 - t;
    return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t;
}

// The curve parameter at which x reaches `fraction` (x is monotonic for x1, x2 in [0, 1]).
double parameterForX(const Curve &curve, double fraction) {
    double lo = 0.0;
    double hi = 1.0;
    for (int i = 0; i < 64 && hi - lo > 1e-15; ++i) {
        const double mid = 0.5 * (lo + hi);
        if (cubic(curve.x1, curve.x2, mid) < fraction) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return 0.5 * (lo + hi);
}

// into / length as a double, from their exact values (both positive for a segment).
double ratio(const ExactTime &into, const ExactTime &length) {
    Int128 numerator = 0;
    Int128 denominator = 0;
    if (!__builtin_mul_overflow(into.numerator(), length.denominator(), &numerator) &&
        !__builtin_mul_overflow(into.denominator(), length.numerator(), &denominator) && denominator != 0) {
        return static_cast<double>(numerator) / static_cast<double>(denominator);
    }
    const double total = length.toDouble();
    return total != 0.0 ? into.toDouble() / total : 0.0;
}

// The curves of the eased interpolations (Core Animation's, control points 0.42 and 0.58).
Curve curveFor(Interpolation interpolation) {
    switch (interpolation) {
    case Interpolation::EaseOut:
        return Curve{0.42, 0.0, 1.0, 1.0};
    case Interpolation::EaseIn:
        return Curve{0.0, 0.0, 0.58, 1.0};
    case Interpolation::EaseInOut:
        return Curve{0.42, 0.0, 0.58, 1.0};
    case Interpolation::Hold:
    case Interpolation::Linear:
    case Interpolation::Bezier:
        break;
    }
    return Curve{};
}

struct CurveSplit {
    std::optional<Curve> before;
    std::optional<Curve> after;
    double valueAtSplit = 0.0;
};

// The two parts of `curve` either side of time fraction `fraction`, each renormalised (De
// Casteljau); a part along which the value does not change is nullopt.
CurveSplit splitCurve(const Curve &curve, double fraction) {
    const double t = parameterForX(curve, std::clamp(fraction, 0.0, 1.0));
    const Point p0{0.0, 0.0};
    const Point p1{curve.x1, curve.y1};
    const Point p2{curve.x2, curve.y2};
    const Point p3{1.0, 1.0};
    const Point a = lerp(p0, p1, t);
    const Point b = lerp(p1, p2, t);
    const Point c = lerp(p2, p3, t);
    const Point d = lerp(a, b, t);
    const Point e = lerp(b, c, t);
    const Point m = lerp(d, e, t);
    CurveSplit split;
    split.valueAtSplit = m.y;
    constexpr double kFlat = 1e-12;
    if (m.x > kFlat && std::fabs(m.y) > kFlat) {
        split.before = Curve{std::clamp(a.x / m.x, 0.0, 1.0), a.y / m.y, std::clamp(d.x / m.x, 0.0, 1.0), d.y / m.y};
    }
    const double restX = 1.0 - m.x;
    const double restY = 1.0 - m.y;
    if (restX > kFlat && std::fabs(restY) > kFlat) {
        split.after = Curve{std::clamp((e.x - m.x) / restX, 0.0, 1.0), (e.y - m.y) / restY,
                            std::clamp((c.x - m.x) / restX, 0.0, 1.0), (c.y - m.y) / restY};
    }
    return split;
}

struct TrackSplit {
    KeyTrack left;
    KeyTrack right;
    double leftStatic = 0.0;
    double rightStatic = 0.0;
};

// A track cut at `at`: the left piece keeps the keyframes before it, the right piece those from it
// on; a cut inside a segment gives both pieces a keyframe at `at` with the value there and divides
// an eased segment's curve exactly. A piece with no keyframe on its side gets that side's constant
// value as its static value.
TrackSplit splitTrack(const KeyTrack &track, double emptyValue, CMTime at) {
    TrackSplit split;
    split.leftStatic = emptyValue;
    split.rightStatic = emptyValue;
    if (track.empty()) {
        return split;
    }
    const auto firstRight =
        std::lower_bound(track.begin(), track.end(), at, [](const Key &k, CMTime t) { return k.time < t; });
    split.left.assign(track.begin(), firstRight);
    split.right.assign(firstRight, track.end());
    if (split.left.empty()) {
        split.leftStatic = track.front().value;
        return split;
    }
    if (split.right.empty()) {
        split.rightStatic = track.back().value;
        return split;
    }
    Key &before = split.left.back();
    if (split.right.front().time == at) {
        split.left.push_back(split.right.front());
        return split;
    }
    const Key &next = split.right.front();
    const auto start = ExactTime::from(before.time);
    const auto end = ExactTime::from(next.time);
    const auto cut = ExactTime::from(at);
    const auto into = start && cut ? cut->minus(*start) : std::nullopt;
    const auto length = start && end ? end->minus(*start) : std::nullopt;
    const double fraction = into && length ? std::clamp(ratio(*into, *length), 0.0, 1.0) : 0.0;
    Key boundary;
    boundary.time = at;
    boundary.interpolation = before.interpolation;
    boundary.curve = before.curve;
    switch (before.interpolation) {
    case Interpolation::Hold:
        boundary.value = before.value;
        break;
    case Interpolation::Linear:
        boundary.value = before.value + (next.value - before.value) * fraction;
        break;
    case Interpolation::EaseOut:
    case Interpolation::EaseIn:
    case Interpolation::EaseInOut:
    case Interpolation::Bezier: {
        const Curve curve = before.interpolation == Interpolation::Bezier ? before.curve : curveFor(before.interpolation);
        const CurveSplit parts = splitCurve(curve, fraction);
        boundary.value = before.value + (next.value - before.value) * parts.valueAtSplit;
        before.interpolation = parts.before ? Interpolation::Bezier : Interpolation::Linear;
        before.curve = parts.before.value_or(Curve{});
        boundary.interpolation = parts.after ? Interpolation::Bezier : Interpolation::Linear;
        boundary.curve = parts.after.value_or(Curve{});
        break;
    }
    }
    split.left.push_back(boundary);
    split.right.insert(split.right.begin(), boundary);
    return split;
}

// Every keyframe time moved by `delta`; false (nothing changed) when a result is not an exact time.
bool shiftTrack(KeyTrack &track, CMTime delta) {
    KeyTrack shifted = track;
    for (Key &key : shifted) {
        const auto moved = checkedAdd(key.time, delta);
        if (!moved || !isExactModelTime(*moved)) {
            return false;
        }
        key.time = *moved;
    }
    track = std::move(shifted);
    return true;
}

// Version 4 keyframes as they were read: an unknown interpolation becomes linear and a curve on a
// keyframe that is not custom is ignored, each with a warning.
Interpolation readInterpolation(const Node &node, Warnings &warnings) {
    const std::string s = node.asString();
    for (const auto &[value, name] : kInterpolations) {
        if (s == name) {
            return value;
        }
    }
    warnings.push_back(node.path() + ": unknown keyframe interpolation \"" + s + "\"; using linear");
    return Interpolation::Linear;
}

Key readKey(const Node &node, Warnings &warnings) {
    node.requireObject();
    Key key;
    key.time = node.field("time").asTime();
    key.value = node.field("value").asDouble();
    key.interpolation = node.has("interpolation") ? readInterpolation(node.field("interpolation"), warnings)
                                                  : Interpolation::Linear;
    if (key.interpolation != Interpolation::Bezier && node.has("curve")) {
        warnings.push_back(node.path() + ": a timing curve on a " + nameOf(key.interpolation) +
                           " keyframe was ignored");
    }
    if (key.interpolation == Interpolation::Bezier) {
        const Node curve = node.field("curve");
        if (curve.arraySize() != 4) {
            curve.fail("expected four numbers [x1, y1, x2, y2]");
        }
        key.curve = Curve{curve.element(0).asDouble(), curve.element(1).asDouble(), curve.element(2).asDouble(),
                          curve.element(3).asDouble()};
    }
    return key;
}

KeyTrack readKeyTrack(const Node &list, Warnings &warnings) {
    KeyTrack track;
    for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
        track.push_back(readKey(list.element(i), warnings));
    }
    return track;
}

// --- Version 4's Motion parameters and what version 5's spans make of them ---

constexpr double kUnbounded = std::numeric_limits<double>::infinity();

struct Parameter {
    const char *name;        // the keyframe track's name in both versions
    const char *displayName; // in warnings
    const char *staticKey;   // the clip's static value in "video"
    double neutral;
    double minimum;
    double maximum;
    bool opacity; // an Opacity span's parameter (the others are a Motion span's)
};

// Version 4's MotionParameter order.
constexpr std::array<Parameter, 5> kParameters{{
    {"x", "Position X", "x", 0.0, -kUnbounded, kUnbounded, false},
    {"y", "Position Y", "y", 0.0, -kUnbounded, kUnbounded, false},
    {"scale", "Scale", "scale", 1.0, 0.0, kUnbounded, false},
    {"rotation", "Rotation", "rotationDegrees", 0.0, -kUnbounded, kUnbounded, false},
    {"opacity", "Opacity", "opacity", 1.0, 0.0, 1.0, true},
}};

bool isValidValue(const Parameter &parameter, double value) {
    return std::isfinite(value) && value >= parameter.minimum && value <= parameter.maximum;
}

double clampValue(const Parameter &parameter, double value) {
    const bool below = std::isfinite(parameter.minimum);
    const bool above = std::isfinite(parameter.maximum);
    if (below && above) {
        return std::clamp(value, parameter.minimum, parameter.maximum);
    }
    if (below) {
        return std::max(parameter.minimum, value);
    }
    if (above) {
        return std::min(parameter.maximum, value);
    }
    return value;
}

// The transition kinds this step accepted when it was frozen. Version 5 itself knew only the cross
// dissolve, but a version 4 file naming a later kind kept it (the 5 -> 6 step then warns), and
// still does; any other name becomes a cross dissolve with a warning.
constexpr std::array<const char *, 6> kTransitionNames{"crossDissolve", "wipeLeft", "wipeRight",
                                                       "wipeUp",        "wipeDown", "iris"};
constexpr const char *kCrossDissolve = "crossDissolve";

std::string readTransitionKind(const Node &node, Warnings &warnings) {
    const std::string s = node.asString();
    if (std::find(kTransitionNames.begin(), kTransitionNames.end(), s) != kTransitionNames.end()) {
        return s;
    }
    warnings.push_back(node.path() + ": unknown transition kind \"" + s + "\"; using a cross dissolve");
    return kCrossDissolve;
}

// --- Version 5's spans and their writer ---

constexpr int kTransitionLane = 0;
constexpr int kFirstEffectLane = 1;
constexpr std::int32_t kPreciseTimescale = 705600000; // version 5's finest model time tick

enum class SpanKind { Transition, Motion, Opacity };

struct Span {
    std::uint64_t id = 0;
    int lane = 0;
    SpanKind kind = SpanKind::Transition;
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;
    bool head = false;                        // transitions: the clip's start (else its end)
    std::string transition = kCrossDissolve;  // transitions
    std::array<KeyTrack, kParameters.size()> tracks; // effect spans, by kParameters index
};

json keyJson(const Key &key) {
    json j{{"time", timeJson(key.time)}, {"value", key.value}, {"interpolation", nameOf(key.interpolation)}};
    if (key.interpolation == Interpolation::Bezier) {
        j["curve"] = json::array({key.curve.x1, key.curve.y1, key.curve.x2, key.curve.y2});
    }
    return j;
}

json spanJson(const Span &span) {
    const char *kind = span.kind == SpanKind::Transition ? "transition"
                       : span.kind == SpanKind::Motion   ? "motion"
                                                         : "opacity";
    json j{{"id", span.id}, {"lane", span.lane}, {"kind", kind}, {"start", timeJson(span.start)},
           {"end", timeJson(span.end)}};
    if (span.kind == SpanKind::Transition) {
        j["edge"] = span.head ? "head" : "tail";
        j["transition"] = span.transition;
        return j;
    }
    json tracks = json::object();
    for (std::size_t p = 0; p < kParameters.size(); ++p) {
        if (!span.tracks[p].empty()) {
            json list = json::array();
            for (const Key &key : span.tracks[p]) {
                list.push_back(keyJson(key));
            }
            tracks[kParameters[p].name] = std::move(list);
        }
    }
    j["tracks"] = std::move(tracks);
    return j;
}

// Version 5's span order on a clip: by lane; on lane 0 the head transition before the tail one,
// on an effect lane by start (a stable sort).
void sortSpans(std::vector<Span> &spans) {
    std::stable_sort(spans.begin(), spans.end(), [](const Span &a, const Span &b) {
        if (a.lane != b.lane) {
            return a.lane < b.lane;
        }
        if (a.kind == SpanKind::Transition || b.kind == SpanKind::Transition) {
            // An effect span's edge is the tail (version 5's default).
            const int edgeA = a.kind == SpanKind::Transition && a.head ? 0 : 1;
            const int edgeB = b.kind == SpanKind::Transition && b.head ? 0 : 1;
            return edgeA < edgeB;
        }
        return a.start < b.start;
    });
}

// A keyframe track of version 4 (source times of the clip) as a span track over the clip's
// source range [in, out]: re-based to `in` and cut exactly at both ends, a side left without
// keyframes holding the value it had. Values a custom curve takes outside the parameter's range at
// a cut are limited, with a warning.
KeyTrack rebasedTrack(const KeyTrack &track, const Parameter &parameter, CMTime in, CMTime out,
                      const std::string &path, Warnings &warnings) {
    KeyTrack relative = track;
    const auto back = checkedNegate(in);
    const auto length = checkedSubtract(out, in);
    if (!back || !length || !shiftTrack(relative, *back)) {
        throw ParseError{path + ": the keyframes cannot be re-based to the clip's source range"};
    }
    auto constant = [](double value) {
        Key key;
        key.value = value;
        return KeyTrack{key};
    };
    if (relative.front().time < kCMTimeZero) {
        TrackSplit pieces = splitTrack(relative, parameter.neutral, kCMTimeZero);
        relative = pieces.right.empty() ? constant(pieces.rightStatic) : std::move(pieces.right);
    }
    if (*length < relative.back().time) {
        TrackSplit pieces = splitTrack(relative, parameter.neutral, *length);
        relative = pieces.left.empty() ? constant(pieces.leftStatic) : std::move(pieces.left);
    }
    for (Key &key : relative) {
        if (!isValidValue(parameter, key.value)) {
            const double limited = clampValue(parameter, key.value);
            warnings.push_back(path + ": a custom curve took " + parameter.displayName + " to " +
                               std::to_string(key.value) + " at the clip's edge; limited to " +
                               std::to_string(limited));
            key.value = limited;
        }
    }
    return relative;
}

// --- Version 4's clips and transitions ---

// The timing of a version 4 clip.
struct Timing {
    std::uint64_t id = 0;
    CMTime timelineStart = kCMTimeZero;
    CMTime timelineDuration = kCMTimeZero;
    CMTime sourceIn = kCMTimeZero;
    bool isStill = false;
    Ratio speed{1, 1};

    CMTime timelineEnd() const {
        return timelineStart + timelineDuration;
    }

    // The source range spans cover: [sourceIn, its out point] ([0, duration] for a still); an out
    // point without an exact time form becomes the finest tick before it.
    std::optional<std::pair<CMTime, CMTime>> spanBounds() const {
        if (isStill) {
            return std::make_pair(kCMTimeZero, timelineDuration);
        }
        const auto inExact = ExactTime::from(sourceIn);
        const auto lengthExact = ExactTime::from(timelineDuration);
        const auto scaled = lengthExact ? lengthExact->times(speed) : std::nullopt;
        const auto out = inExact && scaled ? inExact->plus(*scaled) : std::nullopt;
        if (!out) {
            return std::nullopt;
        }
        if (const auto exact = out->toTime()) {
            return std::make_pair(sourceIn, *exact);
        }
        const CMTime tick = CMTimeMake(1, kPreciseTimescale);
        const auto index = out->frameIndex(tick, SnapMode::Floor);
        const auto bound = index ? checkedTimeForFrame(*index, tick) : std::nullopt;
        if (!bound) {
            return std::nullopt;
        }
        return std::make_pair(sourceIn, *bound);
    }
};

struct LegacyClip {
    json *document = nullptr; // the clip's JSON (updated in place)
    std::string path;
    Timing clip;
    bool audioTrack = false;
    std::array<KeyTrack, kParameters.size()> keyframes;
    CMTime fadeIn = kCMTimeZero;
    CMTime fadeOut = kCMTimeZero;
};

LegacyClip readLegacyClip(json &clipJson, const Node &node, bool audioTrack, Warnings &warnings) {
    node.requireObject();
    LegacyClip legacy;
    legacy.document = &clipJson;
    legacy.path = node.path();
    legacy.audioTrack = audioTrack;
    Timing &clip = legacy.clip;
    clip.id = node.field("id").asUInt64();
    clip.timelineStart = node.field("timelineStart").asTime();
    clip.timelineDuration = node.field("duration").asTime();
    clip.sourceIn = node.field("sourceIn").asTime();
    clip.isStill = node.boolOr("isStill", false);
    if (node.has("speed")) {
        const Node speed = node.field("speed");
        const std::int64_t den = speed.field("den").asInt64();
        if (den <= 0) {
            speed.field("den").fail("speed denominator must be positive");
        }
        clip.speed = Ratio{speed.field("num").asInt64(), den};
    }
    if (node.has("video") && node.field("video").has("keyframes")) {
        const Node keyframes = node.field("video").field("keyframes");
        keyframes.requireObject();
        for (const auto &entry : keyframes.value().items()) {
            const bool known = std::any_of(kParameters.begin(), kParameters.end(),
                                           [&](const Parameter &p) { return entry.key() == p.name; });
            if (!known) {
                warnings.push_back(keyframes.path() + ": unknown Motion parameter \"" + entry.key() +
                                   "\"; its keyframes were dropped");
            }
        }
        for (std::size_t p = 0; p < kParameters.size(); ++p) {
            if (keyframes.has(kParameters[p].name)) {
                legacy.keyframes[p] = readKeyTrack(keyframes.field(kParameters[p].name), warnings);
            }
        }
    }
    if (node.has("audio")) {
        const Node audio = node.field("audio");
        audio.requireObject();
        legacy.fadeIn = audio.timeOr("fadeInDuration", kCMTimeZero);
        legacy.fadeOut = audio.timeOr("fadeOutDuration", kCMTimeZero);
    }
    return legacy;
}

struct LegacyTransition {
    std::uint64_t id = 0;
    std::uint64_t from = 0;
    std::uint64_t to = 0;
    CMTime duration = kCMTimeZero;
    std::string kind = kCrossDissolve;
    std::string path;
};

void migrateSequence(json &sequenceJson, const Node &sequence, std::uint64_t &nextId, Warnings &warnings) {
    const CMTime frameDuration = sequence.field("frameDuration").asTime();
    if (!isPositive(frameDuration)) {
        sequence.field("frameDuration").fail("expected a positive frame duration");
    }
    // Clips per track, in the file's (timeline) order.
    std::vector<std::vector<LegacyClip>> tracks;
    forEachTrack(sequenceJson, sequence, [&](json &track, const Node &trackNode, bool video, std::size_t) {
        std::vector<LegacyClip> clips;
        forEachClip(track, trackNode, [&](json &clipJson, const Node &clipNode) {
            clips.push_back(readLegacyClip(clipJson, clipNode, !video, warnings));
        });
        std::stable_sort(clips.begin(), clips.end(), [](const LegacyClip &a, const LegacyClip &b) {
            return a.clip.timelineStart < b.clip.timelineStart;
        });
        tracks.push_back(std::move(clips));
    });
    std::vector<LegacyTransition> transitions;
    if (sequence.has("transitions")) {
        const Node list = sequence.field("transitions");
        for (std::size_t i = 0, n = list.arraySize(); i < n; ++i) {
            const Node node = list.element(i);
            node.requireObject();
            LegacyTransition transition;
            transition.path = node.path();
            transition.id = node.field("id").asUInt64();
            transition.from = node.field("fromClipId").asUInt64();
            transition.to = node.field("toClipId").asUInt64();
            transition.duration = node.field("duration").asTime();
            transition.kind = readTransitionKind(node.field("kind"), warnings);
            transitions.push_back(transition);
        }
    }
    auto outgoing = [&](std::uint64_t id) -> const LegacyTransition * {
        for (const LegacyTransition &t : transitions) {
            if (t.from == id) {
                return &t;
            }
        }
        return nullptr;
    };
    auto incoming = [&](std::uint64_t id) -> const LegacyTransition * {
        for (const LegacyTransition &t : transitions) {
            if (t.to == id) {
                return &t;
            }
        }
        return nullptr;
    };
    for (const LegacyTransition &transition : transitions) {
        bool found = false;
        for (const std::vector<LegacyClip> &clips : tracks) {
            for (const LegacyClip &clip : clips) {
                found = found || clip.clip.id == transition.from;
            }
        }
        if (!found) {
            Node(sequenceJson, transition.path).fail("its outgoing clip " + std::to_string(transition.from) +
                                                     " does not exist");
        }
    }

    for (std::vector<LegacyClip> &clips : tracks) {
        for (std::size_t i = 0; i < clips.size(); ++i) {
            LegacyClip &legacy = clips[i];
            const Timing &clip = legacy.clip;
            json &clipJson = *legacy.document;
            std::vector<Span> spans;

            // The transition at the clip's end, centred on the cut as version 4 drew it.
            std::optional<Span> tail;
            if (const LegacyTransition *transition = outgoing(clip.id)) {
                const std::int64_t frames = frameIndexAt(transition->duration, frameDuration, SnapMode::Round);
                const auto before = checkedTimeForFrame(frames / 2, frameDuration);
                const auto after = checkedTimeForFrame(frames - frames / 2, frameDuration);
                const auto start = before ? checkedNegate(*before) : std::nullopt;
                if (!start || !after) {
                    Node(sequenceJson, transition->path).fail("its duration cannot be converted");
                }
                Span span;
                span.id = transition->id;
                span.lane = kTransitionLane;
                span.kind = SpanKind::Transition;
                span.head = false;
                span.transition = transition->kind;
                span.start = *start;
                span.end = *after;
                tail = span;
            }

            // Motion and opacity keyframes: spans over the clip's source range.
            const bool animated = std::any_of(legacy.keyframes.begin(), legacy.keyframes.end(),
                                              [](const KeyTrack &track) { return !track.empty(); });
            json &video = clipJson["video"];
            if (animated) {
                const auto bounds = clip.spanBounds();
                if (!bounds) {
                    Node(clipJson, legacy.path).fail("its source range overflows exact arithmetic");
                }
                Span motion;
                motion.kind = SpanKind::Motion;
                motion.lane = kFirstEffectLane;
                motion.start = bounds->first;
                motion.end = bounds->second;
                Span opacity = motion;
                opacity.kind = SpanKind::Opacity;
                bool hasMotion = false;
                bool hasOpacity = false;
                for (std::size_t p = 0; p < kParameters.size(); ++p) {
                    const KeyTrack &track = legacy.keyframes[p];
                    if (track.empty()) {
                        continue;
                    }
                    const Parameter &parameter = kParameters[p];
                    const std::string path = legacy.path + ".video.keyframes." + parameter.name;
                    KeyTrack rebased = rebasedTrack(track, parameter, bounds->first, bounds->second, path, warnings);
                    // The span now carries the whole value: the static value (unused by version 4)
                    // becomes neutral.
                    video[parameter.staticKey] = parameter.neutral;
                    if (parameter.opacity) {
                        opacity.tracks[p] = std::move(rebased);
                        hasOpacity = true;
                    } else {
                        motion.tracks[p] = std::move(rebased);
                        hasMotion = true;
                    }
                }
                if (hasMotion) {
                    motion.id = nextId++;
                    spans.push_back(std::move(motion));
                }
                if (hasOpacity) {
                    opacity.id = nextId++;
                    opacity.lane = hasMotion ? kFirstEffectLane + 1 : kFirstEffectLane;
                    spans.push_back(std::move(opacity));
                }
            }
            if (video.is_object()) {
                video.erase("keyframes");
            }

            // Fades: audio clips only (version 4 never applied them to video), and not on an edge
            // with a crossfade (version 4 ignored the fade there).
            std::optional<Span> head;
            if (legacy.audioTrack) {
                const bool touchedAtHead = i > 0 && clips[i - 1].clip.timelineEnd() == clip.timelineStart;
                if (kCMTimeZero < legacy.fadeIn && incoming(clip.id) == nullptr) {
                    if (touchedAtHead) {
                        warnings.push_back(legacy.path + ".audio.fadeInDuration: the fade in (" +
                                           describeTime(legacy.fadeIn) + ") was dropped: another clip touches the "
                                           "clip's start, and the cut there belongs to that clip");
                    } else {
                        Span span;
                        span.id = nextId++;
                        span.lane = kTransitionLane;
                        span.kind = SpanKind::Transition;
                        span.head = true;
                        span.start = kCMTimeZero;
                        span.end = legacy.fadeIn;
                        head = span;
                    }
                }
                CMTime fadeOut = legacy.fadeOut;
                if (kCMTimeZero < fadeOut && !tail) {
                    if (const LegacyTransition *crossfade = incoming(clip.id)) {
                        // Version 4 multiplied a fade out with a crossfade into the clip; a fade
                        // span must leave room for the crossfade's part inside the clip (its
                        // centred span's end: ceil(n / 2) frames).
                        const std::int64_t frames = frameIndexAt(crossfade->duration, frameDuration, SnapMode::Round);
                        const auto inside = checkedTimeForFrame(frames - frames / 2, frameDuration);
                        const auto room = inside ? checkedSubtract(clip.timelineDuration, *inside) : std::nullopt;
                        if (!room || *room < fadeOut) {
                            const CMTime kept = room ? maxTime(*room, kCMTimeZero) : kCMTimeZero;
                            warnings.push_back(legacy.path + ".audio.fadeOutDuration: the fade out (" +
                                               describeTime(fadeOut) +
                                               ") would meet the crossfade at the clip's start; " +
                                               (kCMTimeZero < kept ? "shortened to " + describeTime(kept)
                                                                   : std::string("dropped")));
                            fadeOut = kept;
                        }
                    }
                }
                if (kCMTimeZero < fadeOut && !tail) {
                    const auto start = checkedNegate(fadeOut);
                    if (!start) {
                        Node(clipJson, legacy.path).fail("its fade out cannot be converted");
                    }
                    Span span;
                    span.id = nextId++;
                    span.lane = kTransitionLane;
                    span.kind = SpanKind::Transition;
                    span.head = false;
                    span.start = *start;
                    span.end = kCMTimeZero;
                    tail = span;
                }
            }
            if (head && tail && kCMTimeZero < tail->end) {
                // Version 4 applied a fade in under a crossfade at the other end; a fade span must
                // leave room for the crossfade's part inside the clip.
                const auto room = checkedAdd(clip.timelineDuration, tail->start);
                if (!room || !(head->end <= *room)) {
                    const CMTime kept = room ? maxTime(*room, kCMTimeZero) : kCMTimeZero;
                    warnings.push_back(legacy.path + ".audio.fadeInDuration: the fade in (" + describeTime(head->end) +
                                       ") would meet the crossfade at the clip's end; " +
                                       (kCMTimeZero < kept ? "shortened to " + describeTime(kept)
                                                           : std::string("dropped")));
                    head->end = kept;
                    if (!(kCMTimeZero < kept)) {
                        head.reset();
                    }
                }
            }
            if (head) {
                spans.push_back(*head);
            }
            if (tail) {
                spans.push_back(*tail);
            }
            json &audio = clipJson["audio"];
            if (audio.is_object()) {
                audio.erase("fadeInDuration");
                audio.erase("fadeOutDuration");
            }
            sortSpans(spans);
            if (!spans.empty()) {
                json list = json::array();
                for (const Span &span : spans) {
                    list.push_back(spanJson(span));
                }
                clipJson["spans"] = std::move(list);
            }
        }
    }
    sequenceJson.erase("transitions");
}

void migrate(json &document, const StepContext &context) {
    const Node root(document, "");
    root.requireObject();
    std::uint64_t nextId = root.field("nextId").asUInt64();
    forEachSequence(document, [&](json &sequence, const Node &node) {
        migrateSequence(sequence, node, nextId, context.warnings);
    });
    document["nextId"] = nextId;
}

} // namespace toV5

// ===== 5 -> 6 =====

namespace toV6 {

// The transition kinds version 6 added, with the names its warnings use.
constexpr std::array<std::pair<const char *, const char *>, 5> kVersion6Transitions{{
    {"wipeLeft", "Wipe Left"},
    {"wipeRight", "Wipe Right"},
    {"wipeUp", "Wipe Up"},
    {"wipeDown", "Wipe Down"},
    {"iris", "Iris"},
}};

// Version 6 added clips' "reversed" flag (absent means forward) and the wipe and iris transition
// kinds: a version 5 file has neither, so only the version number changes. One that has them anyway
// (written by hand, or by a build between the two) keeps them, with a warning naming each (review
// L8); the project is then saved in the current version, as every project is.
void migrate(json &document, const StepContext &context) {
    const std::string feature = " is a version 6 feature in a project of an earlier version: kept, and the "
                                "project is saved as version " +
                                std::to_string(context.targetVersion);
    forEachSequence(document, [&](json &sequence, const Node &node) {
        forEachTrack(sequence, node, [&](json &track, const Node &trackNode, bool, std::size_t) {
            forEachClip(track, trackNode, [&](json &clip, const Node &clipNode) {
                const auto reversed = clip.find("reversed");
                if (reversed != clip.end() && reversed->is_boolean() && reversed->get<bool>()) {
                    context.warnings.push_back(clipNode.path() + ": \"reversed\"" + feature);
                }
                if (!clipNode.has("spans")) {
                    return;
                }
                const Node spans = clipNode.field("spans");
                for (std::size_t i = 0, n = spans.arraySize(); i < n; ++i) {
                    const Node span = spans.element(i);
                    span.requireObject();
                    const auto kind = span.value().find("transition");
                    if (kind == span.value().end() || !kind->is_string()) {
                        continue;
                    }
                    const std::string name = kind->get<std::string>();
                    for (const auto &[fileName, displayName] : kVersion6Transitions) {
                        if (name == fileName) {
                            const bool vowel = std::string("AEIOU").find(displayName[0]) != std::string::npos;
                            context.warnings.push_back(span.path() + ": " + (vowel ? "an " : "a ") + displayName +
                                                       " transition" + feature);
                        }
                    }
                }
            });
        });
    });
}

} // namespace toV6

// ===== 6 -> 7 =====

namespace toV7 {

// Version 7 added the sequence settings' "configured" flag (a new project's sequence takes its first
// video clip's size and frame rate until it is configured) and the project's
// "sharpenScaledDownSources". A version 6 project was made before either existed: its sequences
// keep the settings they have (configured) and scaled-down sources are sharpened (the default). The
// step writes both explicitly; nothing else changes.
void migrate(json &document, const StepContext &) {
    Node(document, "").requireObject();
    document["sharpenScaledDownSources"] = true;
    forEachSequence(document, [](json &sequence, const Node &) { sequence["configured"] = true; });
}

} // namespace toV7

// ===== 7 -> 8 =====

namespace toV8 {

// Version 8 added a clip's "grade" (its colour correction; absent means no grade). A version 7 file
// has none, so only the version number changes. One that has it anyway (written by hand, or by a
// build between the two) keeps it, with a warning naming each clip, as the 5 -> 6 step does for
// version 6 content; the project is then saved in the current version.
void migrate(json &document, const StepContext &context) {
    Node(document, "").requireObject();
    const std::string feature = ": \"grade\" is a version 8 feature in a project of an earlier version: kept, and the "
                                "project is saved as version " +
                                std::to_string(context.targetVersion);
    forEachSequence(document, [&](json &sequence, const Node &node) {
        forEachTrack(sequence, node, [&](json &track, const Node &trackNode, bool, std::size_t) {
            forEachClip(track, trackNode, [&](json &clip, const Node &clipNode) {
                if (clip.find("grade") != clip.end()) {
                    context.warnings.push_back(clipNode.path() + feature);
                }
            });
        });
    });
}

} // namespace toV8

struct MigrationStep {
    int fromVersion;
    void (*apply)(json &document, const StepContext &context);
};

// One entry per schema version bump, in order: entry i upgrades fromVersion to fromVersion + 1.
constexpr MigrationStep kMigrations[] = {
    {1, toV2::migrate}, {2, toV3::migrate}, {3, toV4::migrate},
    {4, toV5::migrate}, {5, toV6::migrate}, {6, toV7::migrate}, {7, toV8::migrate},
};

constexpr bool migrationsInOrder() {
    int expected = 1;
    for (const MigrationStep &step : kMigrations) {
        if (step.fromVersion != expected) {
            return false;
        }
        ++expected;
    }
    return expected == kLastMigrationTarget;
}
static_assert(migrationsInOrder(), "one migration step per version, in order, ending at kLastMigrationTarget");

} // namespace

void runProjectMigrations(json &document, int fromVersion, int toVersion, std::vector<std::string> &warnings) {
    const StepContext context{warnings, toVersion};
    for (const MigrationStep &step : kMigrations) {
        if (step.fromVersion >= fromVersion && step.fromVersion < toVersion) {
            step.apply(document, context);
            document["schemaVersion"] = step.fromVersion + 1;
        }
    }
}

} // namespace ve::serialize
