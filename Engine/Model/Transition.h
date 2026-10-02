// Transitions: what a TransitionSpan (EffectSpan.h; lane 0 of a clip, Clip::transitions) does.
//
// A transition is a span on lane 0 of the clip that owns it. Where it sits decides its role:
// - At the clip's tail (ClipEdge::Tail) it covers the timeline range [cut + start, cut + end]
//   around the cut at the clip's end (start <= 0 <= end, offsets in sequence time). When it runs
//   past the cut (end > 0) it overlays the clip that touches the owner's end on the same track: a
//   cross dissolve (video) or a constant-power crossfade (audio) whose share of each side is the
//   range's split at the cut, using the owner's media after its out point and the next clip's
//   media before its in point (the handles). A tail span ending on the cut (end == 0) is a fade
//   out to black (video) or silence (audio) inside the clip, touching neighbour or not.
// - At the clip's head (ClipEdge::Head) it is a fade in from black or silence over
//   [clip start, clip start + end] (start == 0), allowed only when no clip touches the owner's
//   start: a cut between two touching clips belongs to the outgoing (left) clip, so it takes one
//   transition at most, the outgoing clip's.
// Validation lives in Validation.h (checkTransitionSpan).

#pragma once

#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace ve {

// The kind of transition a lane-0 span makes: how the picture changes over the linear progress p
// (LayerTransition::mix, 0 at the start of the range, 1 at its end). The kind is a video property:
// audio always uses a constant-power crossfade across a cut (constantPowerGain of the linear
// progress) or a linear fade against silence at a free edge, and a transition span on an audio
// track is always CrossDissolve (checkTransitionSpan). Where no clip is on the other side (a fade
// role), the other picture is black, or the tracks below. The shaped kinds reveal the incoming
// picture per pixel through a soft edge, by default kTransitionFeather sequence pixels wide on each
// side (TransitionParameter::Softness; RenderGraph.h, transitionReveal); p = 0 shows none of it and
// p = 1 all of it. What the engine knows of each kind is its row of the kind table below.
enum class TransitionKind {
    // Every pixel mixes linearly: (1 - p) of the outgoing picture and p of the incoming one.
    CrossDissolve,
    // The incoming picture enters from the right edge; the edge between them travels left.
    WipeLeft,
    // The incoming picture enters from the left edge; the edge between them travels right.
    WipeRight,
    // The incoming picture enters from the bottom edge; the edge between them travels up.
    WipeUp,
    // The incoming picture enters from the top edge; the edge between them travels down.
    WipeDown,
    // The incoming picture shows inside a circle growing from the frame's centre until it covers
    // the corners. Iris opens on a cut or a fade-in and closes on a fade-out: at a clip's end the
    // picture stays inside a circle shrinking to the centre, black coming in from the corners.
    Iris,
};

inline constexpr std::array<TransitionKind, 6> kTransitionKinds{
    TransitionKind::CrossDissolve, TransitionKind::WipeLeft, TransitionKind::WipeRight,
    TransitionKind::WipeUp,        TransitionKind::WipeDown, TransitionKind::Iris};

// The kind of track a clip lies on (Track.h).
enum class TrackKind;

// ----- Transition kinds and parameters: one descriptor table each (grading decision, section 8) -----
// Everything the engine knows about a kind or a parameter of a transition is a row of these tables
// (Transition.cpp), as SpanKindInfo / SpanParameterInfo are for effect spans (EffectSpan.h): adding a
// parameter is adding a row (and an enumerator), and the project file's parser and writer, validation,
// the kind change and the scheduler read it from there.

// How a kind reveals the incoming picture (RenderGraph.h, transitionReveal): the family of its reveal
// mask m, a signed distance from an edge with a soft band around it.
enum class TransitionMask {
    None,   // no mask: every pixel mixes linearly (the cross dissolve)
    Linear, // a straight edge across the frame, entering from one side (the wipes)
    Radial, // a circle about the frame's centre (the iris; it closes on the picture at a fade out)
};

// The parameters a transition span can set (static values: TransitionParameters).
enum class TransitionParameter {
    // The half width f, in sequence pixels, of a shaped kind's soft edge: at one instant the reveal goes
    // from 0 to 1 across 2f pixels (RenderGraph.h, kTransitionFeather). 0 is a hard edge.
    Softness,
};

inline constexpr std::size_t kTransitionParameterCount = 1;
inline constexpr std::array<TransitionParameter, kTransitionParameterCount> kTransitionParameters{
    TransitionParameter::Softness};

// The default softness: the 2 px soft edge every shaped transition had before the parameter existed.
inline constexpr double kDefaultTransitionSoftness = 2.0;

// What a parameter's value is, and so which components of a TransitionValue it uses and how the project
// file writes it.
enum class TransitionParameterType {
    Scalar, // one number: components[0]; the file writes a number
    Angle,  // degrees, clockwise from the +x axis (y points down): components[0]; a number
    Point,  // x, y as fractions of the frame's width and height (0, 0 top left): components[0..1]; [x, y]
    Colour, // red, green, blue, alpha, 0...1, gamma-encoded like the sequence: components[0..3]; [r, g, b, a]
    Enum,   // the index of one of the parameter's choices: components[0]; the file writes the choice's name
};

// The number of components a value of `type` uses: 1, 1, 2, 4, 1.
constexpr std::size_t componentCountOf(TransitionParameterType type) {
    switch (type) {
    case TransitionParameterType::Point:
        return 2;
    case TransitionParameterType::Colour:
        return 4;
    case TransitionParameterType::Scalar:
    case TransitionParameterType::Angle:
    case TransitionParameterType::Enum:
        break;
    }
    return 1;
}

// One static value of a transition parameter. Its type (TransitionParameterInfo::type) says which
// components it uses (componentCountOf); the others are always 0, so equal values compare equal.
struct TransitionValue {
    std::array<double, 4> components{};

    static constexpr TransitionValue scalar(double value) {
        return TransitionValue{{value, 0.0, 0.0, 0.0}};
    }
    static constexpr TransitionValue point(double x, double y) {
        return TransitionValue{{x, y, 0.0, 0.0}};
    }
    static constexpr TransitionValue colour(double red, double green, double blue, double alpha) {
        return TransitionValue{{red, green, blue, alpha}};
    }
    static constexpr TransitionValue choice(std::size_t index) {
        return TransitionValue{{static_cast<double>(index), 0.0, 0.0, 0.0}};
    }

    friend bool operator==(const TransitionValue &, const TransitionValue &) = default;
};

struct TransitionParameterInfo {
    TransitionParameter parameter;
    const char *name;        // the project file's key in a span's "parameters": "softness"
    const char *displayName; // messages: "Edge Softness"
    TransitionParameterType type;
    TransitionValue defaultValue; // what a span that does not set the parameter uses
    // The valid range of each component the type uses, [minimum, maximum] (finite values only). An Enum
    // is bounded by its choices instead.
    double minimum;
    double maximum;
    std::span<const char *const> choices; // an Enum's choices, as the file names them; none otherwise
};

struct TransitionKindInfo {
    TransitionKind kind;
    const char *name;        // the project file's name ("crossDissolve", "wipeLeft", ...)
    const char *displayName; // messages ("Cross Dissolve", "Wipe Left", ...)
    // The kind of track it may lie on (TrackKind::Video), or nullopt for either: audio has only the
    // crossfade (and fades), so only the cross dissolve fits both.
    std::optional<TrackKind> trackKind;
    TransitionMask mask;
    std::span<const TransitionParameter> parameters; // in TransitionParameter order
};

// The row of `kind` / `parameter` (the first row for a value outside the enum, never made by the engine).
const TransitionKindInfo &infoOf(TransitionKind kind);
const TransitionParameterInfo &infoOf(TransitionParameter parameter);

// "crossDissolve", "wipeLeft", "wipeRight", "wipeUp", "wipeDown", "iris" (the project file's names).
const char *nameOf(TransitionKind kind);
// "Cross Dissolve", "Wipe Left", "Wipe Right", "Wipe Up", "Wipe Down", "Iris" (messages).
const char *displayNameOf(TransitionKind kind);
// The kind named `name` (nameOf), or nullopt.
std::optional<TransitionKind> transitionKindNamed(std::string_view name);
// Whether a transition of `kind` may lie on a clip of a `track` track (TransitionKindInfo::trackKind).
bool transitionKindFitsTrack(TransitionKind kind, TrackKind track);
// Whether `kind` reveals through a mask (a wipe or the iris), not a uniform mix.
bool isShapedTransition(TransitionKind kind);

// "softness" (the project file's keys).
const char *nameOf(TransitionParameter parameter);
// "Edge Softness" (messages).
const char *displayNameOf(TransitionParameter parameter);
// The parameter named `name` (nameOf), or nullopt.
std::optional<TransitionParameter> transitionParameterNamed(std::string_view name);
// Whether transitions of `kind` have `parameter` (TransitionKindInfo::parameters).
bool transitionKindHasParameter(TransitionKind kind, TransitionParameter parameter);
// Whether `value` is a valid value of the parameter `info` describes: the components its type uses
// finite and within [minimum, maximum] (an Enum's an integral index of one of its choices), the others 0.
bool isValidTransitionValue(const TransitionParameterInfo &info, const TransitionValue &value);
bool isValidTransitionValue(TransitionParameter parameter, const TransitionValue &value);

// The static parameter values a transition span sets, indexed by TransitionParameter (only its kind's
// may be set); a parameter it does not set has its default (TransitionParameterInfo::defaultValue).
// Values set to the default stay set, so a file reads and writes back as it was.
struct TransitionParameters {
    std::array<std::optional<TransitionValue>, kTransitionParameterCount> byParameter;

    std::optional<TransitionValue> &operator[](TransitionParameter parameter) {
        return byParameter[index(parameter)];
    }
    const std::optional<TransitionValue> &operator[](TransitionParameter parameter) const {
        return byParameter[index(parameter)];
    }
    // The value of `parameter`: the one set, else its default.
    TransitionValue valueOf(TransitionParameter parameter) const;
    // No parameter is set.
    bool empty() const;

    friend bool operator==(const TransitionParameters &, const TransitionParameters &) = default;

  private:
    // A value outside the enum (never made by the engine) reads and writes the first slot rather than
    // past the end.
    static std::size_t index(TransitionParameter parameter) {
        const auto i = static_cast<std::size_t>(parameter);
        return i < kTransitionParameterCount ? i : 0;
    }
};

// Why `parameters` cannot belong to a transition of `kind` (a parameter the kind does not have, or an
// invalid value), as a sentence naming the parameter; nullopt when they can.
std::optional<std::string> transitionParametersProblem(TransitionKind kind, const TransitionParameters &parameters);
// The values of `parameters` a transition of `kind` keeps (those of its parameters); the rest are unset.
TransitionParameters parametersKeptBy(TransitionKind kind, const TransitionParameters &parameters);

// What a transition span does where it sits (see the top of this file).
enum class TransitionRole {
    CrossDissolve, // across the cut into the touching next clip
    FadeOut,       // to black / silence at the owner's end
    FadeIn,        // from black / silence at the owner's start
};

// "crossDissolve", "fadeOut", "fadeIn".
const char *nameOf(TransitionRole role);

} // namespace ve
