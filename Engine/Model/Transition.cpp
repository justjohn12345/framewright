#include "Transition.h"

namespace ve {

const char *nameOf(TransitionKind kind) {
    switch (kind) {
    case TransitionKind::CrossDissolve:
        return "crossDissolve";
    }
    return "unknown";
}

} // namespace ve
