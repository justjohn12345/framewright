#include "Transition.h"

namespace ve {

const char *nameOf(TransitionKind kind) {
    switch (kind) {
    case TransitionKind::CrossDissolve:
        return "crossDissolve";
    case TransitionKind::WipeLeft:
        return "wipeLeft";
    case TransitionKind::WipeRight:
        return "wipeRight";
    case TransitionKind::WipeUp:
        return "wipeUp";
    case TransitionKind::WipeDown:
        return "wipeDown";
    case TransitionKind::Iris:
        return "iris";
    }
    return "unknown";
}

const char *displayNameOf(TransitionKind kind) {
    switch (kind) {
    case TransitionKind::CrossDissolve:
        return "Cross Dissolve";
    case TransitionKind::WipeLeft:
        return "Wipe Left";
    case TransitionKind::WipeRight:
        return "Wipe Right";
    case TransitionKind::WipeUp:
        return "Wipe Up";
    case TransitionKind::WipeDown:
        return "Wipe Down";
    case TransitionKind::Iris:
        return "Iris";
    }
    return "Unknown";
}

std::optional<TransitionKind> transitionKindNamed(std::string_view name) {
    for (const TransitionKind kind : kTransitionKinds) {
        if (name == nameOf(kind)) {
            return kind;
        }
    }
    return std::nullopt;
}

const char *nameOf(TransitionRole role) {
    switch (role) {
    case TransitionRole::CrossDissolve:
        return "crossDissolve";
    case TransitionRole::FadeOut:
        return "fadeOut";
    case TransitionRole::FadeIn:
        return "fadeIn";
    }
    return "unknown";
}

} // namespace ve
