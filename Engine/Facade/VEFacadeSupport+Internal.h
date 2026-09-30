// What every file of the facade implementation shares, VEEngine's files and the classes VEEngine
// coordinates (VEExporter, VEMediaLibrary, VESourceMonitor, VEProgramMonitor) alike: the
// hidden-visibility marker, the main-thread check and small playback helpers. It knows nothing of
// VEEngine, so those classes can include it without seeing the engine.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import <Foundation/Foundation.h>

#include "../Playback/PlaybackController.h"

/// Marks a function shared by the facade's files as private to the framework: visible to the other
/// facade files, not exported from FramewrightEngine (the helpers below were file-local before the
/// facade was split and must not become framework API).
#define VE_FACADE_HIDDEN __attribute__((visibility("hidden")))

NS_ASSUME_NONNULL_BEGIN
/// Raises NSInternalInconsistencyException ("must be used on the main thread (<function> called on
/// <thread>)"): a method of the facade (VEEngine or a class it coordinates) was called off the main
/// thread (VEFacadeSupport.mm).
[[noreturn]] VE_FACADE_HIDDEN void veMainThreadViolation(const char *function);
NS_ASSUME_NONNULL_END

/// The facade's model and monitor calls are confined to the main thread. Active in every build
/// configuration: a call from another thread would race the model, so it fails loudly instead.
#define VE_ASSERT_MAIN()                                                                                               \
    do {                                                                                                               \
        if (__builtin_expect(!NSThread.isMainThread, 0)) {                                                             \
            veMainThreadViolation(__PRETTY_FUNCTION__);                                                                \
        }                                                                                                              \
    } while (0)

namespace ve::facade {

/// Whether a playback controller in `state` is playing or pre-rolling.
VE_FACADE_HIDDEN inline bool isRunning(playback::PlaybackState state) {
    return state == playback::PlaybackState::Playing || state == playback::PlaybackState::Prerolling;
}

} // namespace ve::facade
