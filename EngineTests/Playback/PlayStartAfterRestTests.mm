// Play start where the playhead was put down: after playing, a pause, then the playhead put down at one place and then
// another (a scrub's end, a ruler click, a seek) before Space. The audio sources must be ready at the last place
// while stopped, so the pre-roll finds them primed; PlayStartMeasurementTests (the Measurements scheme) times it.

#import <XCTest/XCTest.h>

#include "../Audio/AudioTestSupport.h"
#include "PlaybackTestSupport.h"

#include <chrono>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

int64_t sampleAt(CMTime t) {
    return static_cast<int64_t>(std::llround(CMTimeGetSeconds(t) * 48000.0));
}

} // namespace

@interface PlayStartAfterRestTests : XCTestCase
@end

@implementation PlayStartAfterRestTests

/// A source's ring keeps the audio it decoded for the place it played from until its consumer (the render thread)
/// skips it, and a stopped mixer reads nothing: after playing, the first place the playhead was put down filled what
/// the ring had left, and the second found it full, so its audio was never decoded while stopped and the next play
/// waited for the pre-roll timeout (a second) before starting without it. The stopped render callbacks now take up
/// the newest place, so each place gets ready while stopped.
- (void)testTheAudioGetsReadyAtEveryPlaceThePlayheadIsPutDownWhileStopped {
    ToneRig rig(1);
    rig.load();
    rig.startPump();
    XCTAssertTrue(rig.waitForState(PlaybackState::Stopped));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.out->isRunning(); }), @"the output runs");

    // Play long enough for the source to have decoded its whole lookahead ahead of the playhead, then pause.
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return CMTimeGetSeconds(rig.controller->currentTime()) >= 1.5; }));
    rig.controller->pause();
    XCTAssertTrue(rig.waitForState(PlaybackState::Stopped));

    // Put down at one place, then at others, each time waiting while stopped.
    for (CMTime at : {CMTimeMake(4, 1), CMTimeMake(7, 1), CMTimeMake(2, 1), CMTimeMake(8, 1)}) {
        rig.controller->seek(at);
        XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->mixer().isPrimed(at); },
                                                 std::chrono::seconds(5)),
                      @"the audio at %.0f s is decoded while stopped (%s)", CMTimeGetSeconds(at),
                      [&] {
                          const auto stats = rig.controller->mixer().stats();
                          return stats.sources.empty() ? std::string("no source")
                                                       : "buffered " + std::to_string(stats.sources[0].bufferedFrames);
                      }()
                          .c_str());
    }
    // Space then starts on the primed audio: the clock runs from the playhead at once and nothing underruns.
    const uint64_t underruns = rig.controller->mixer().stats().underruns;
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing, std::chrono::milliseconds(500)),
                  @"the pre-roll does not wait for its timeout");
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->mixer().stats().position > sampleAt(CMTimeMake(81, 10)); }),
                  @"the audio plays from 8 s");
    XCTAssertEqual(rig.controller->mixer().stats().underruns, underruns, @"no underrun at the start");
    rig.controller->pause();
}

@end
