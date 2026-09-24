#include "Transition.h"

namespace ve {

const char *nameOf(TransitionKind kind) {
    switch (kind) {
    case TransitionKind::CrossDissolve:
        return "crossDissolve";
    }
    return "unknown";
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
