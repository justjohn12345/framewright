// The opt-in stress tests (EngineTests/Stress, and AppTests' TwoHourProjectStressTests) run only in
// the StressTests scheme, which selects them and sets FRAMEWRIGHT_STRESS=1; the other schemes skip
// them by name. The variable also guards a run started any other way (one test from Xcode's test
// navigator, `-only-testing:`): without it the test reports a skip that says how to run it.
#pragma once

#include <cstdlib>
#include <cstring>

namespace ve::test {

/// Whether FRAMEWRIGHT_STRESS=1 is set.
inline bool stressTestsEnabled() {
    const char *value = std::getenv("FRAMEWRIGHT_STRESS");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

} // namespace ve::test

/// Skips the calling XCTest method unless the stress tests are enabled.
#define VE_REQUIRE_STRESS_TESTS()                                                                                      \
    do {                                                                                                               \
        if (!ve::test::stressTestsEnabled()) {                                                                         \
            XCTSkip(@"a long-running stress test: run it with the StressTests scheme "                                 \
                    @"(xcodebuild -scheme StressTests -destination 'platform=macOS' test), which sets "               \
                    @"FRAMEWRIGHT_STRESS=1");                                                                          \
        }                                                                                                              \
    } while (false)
