#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/Apple/AppleProber.h"
#include "../../Engine/Media/Apple/AppleVideoDecoder.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "../../Engine/Media/MediaTypes.h"
#include "TestMedia.h"

#import <VideoToolbox/VideoToolbox.h>

#include <cstdlib>
#include <string>

using namespace ve::media;

@interface HardwareCapsTests : XCTestCase
@end

@implementation HardwareCapsTests

- (void)testProbeReportsThisMachine {
    const HardwareCaps &caps = HardwareCaps::get();
    NSLog(@"VideoToolbox capabilities:\n%s", caps.description().c_str());
    XCTAssertEqual(&caps, &HardwareCaps::get(), @"probed once and cached");
#if defined(__arm64__)
    // Every Apple silicon Mac has H.264 and HEVC decode and encode engines.
    XCTAssertTrue(caps.h264.hardwareDecode);
    XCTAssertTrue(caps.hevc.hardwareDecode);
    XCTAssertTrue(caps.h264.hardwareEncode);
    XCTAssertTrue(caps.hevc.hardwareEncode);
    XCTAssertFalse(caps.h264.hardwareEncoderIDs.empty());
#endif
    // Software H.264/HEVC encoders always exist next to the hardware ones on macOS.
    XCTAssertTrue(caps.h264.hardwareEncode || caps.h264.softwareEncode);
}

- (void)testCodecTypeMapping {
    const HardwareCaps &caps = HardwareCaps::get();
    XCTAssertEqual(caps.forCodecType(fourcc::H264), &caps.h264);
    XCTAssertEqual(caps.forCodecType(fourcc::make("avc3")), &caps.h264);
    XCTAssertEqual(caps.forCodecType(fourcc::HEVCAlt), &caps.hevc);
    XCTAssertEqual(caps.forCodecType(fourcc::ProRes422HQ), &caps.prores);
    XCTAssertEqual(caps.forCodecType(fourcc::ProRes4444), &caps.prores);
    XCTAssertEqual(caps.forCodecType(fourcc::AV1), &caps.av1);
    XCTAssertEqual(caps.forCodecType(fourcc::VP9), &caps.vp9);
    XCTAssertEqual(caps.forCodecType(fourcc::AAC), nullptr);
    XCTAssertFalse(caps.hardwareDecode(fourcc::AAC));
    XCTAssertEqual(caps.hardwareDecode(fourcc::ProRes4444), caps.prores.hardwareDecode);
    XCTAssertEqual(&caps.forCodec(HWCodec::AV1), &caps.av1);
}

// MARK: - Supplemental decoders (review B9)

/// Review B9 (general review, 2026-10-01): VideoToolbox's supplemental decoders were registered only as a side
/// effect of HardwareCaps::get(), which the prober never called, so a probe made first in a process could
/// find no decoder for the codec (measured as not decodable by VideoToolbox) and the routing stuck for that
/// asset. Registration is explicit now, from every VideoToolbox entry point. Only a fresh process shows it
/// (the first registration is for the whole process), so each case runs the child test below in a new
/// xctest process. On this OS AV1 needs no registration any more (VTIsHardwareDecodeSupported('av01') is
/// true before it); VP9 still does, so the children check VP9.
- (void)testTheProberAndTheBackendRegisterTheSupplementalDecodersInAFreshProcess {
    registerSupplementalVideoDecoders();
    if (!VTIsHardwareDecodeSupported(fourcc::VP9)) {
        XCTSkip(@"this Mac has no VP9 hardware decoder to register");
    }
    std::string error;
    const std::string h264 = ve::test::testMediaPath("h264_1080p30.mp4", error);
    XCTAssertFalse(h264.empty(), @"%s", error.c_str());
    for (NSString *entry in @[ @"prober", @"backend", @"decoder" ]) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        task.arguments = @[
            @"xctest", @"-XCTest", @"HardwareCapsTests/testChildFirstVideoToolboxUseRegistersVP9",
            [NSBundle bundleForClass:[self class]].bundlePath
        ];
        // This process's environment (the framework search paths xcodebuild set), without the variables that
        // tie a test process to the running test session.
        NSMutableDictionary *environment = [NSMutableDictionary dictionary];
        [NSProcessInfo.processInfo.environment
            enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *) {
              if (![key hasPrefix:@"XCTest"] && ![key hasPrefix:@"XCInject"]) {
                  environment[key] = value;
              }
            }];
        environment[@"FRAMEWRIGHT_B9_CHILD_ENTRY"] = entry;
        environment[@"FRAMEWRIGHT_B9_CHILD_FILE"] = @(h264.c_str());
        // A coverage build's profile of the child goes to the child's own scratch directory (removed with
        // it), not into this run's profile or the working directory.
        NSString *scratch = @(ve::test::scratchDirectory().c_str());
        environment[@"LLVM_PROFILE_FILE"] = [scratch stringByAppendingPathComponent:@"child.profraw"];
        task.currentDirectoryURL = [NSURL fileURLWithPath:scratch isDirectory:YES];
        task.environment = environment;
        NSPipe *output = [NSPipe pipe];
        task.standardOutput = output;
        task.standardError = output;
        NSError *launchError = nil;
        XCTAssertTrue([task launchAndReturnError:&launchError], @"%@", launchError);
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSString *log = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        XCTAssertEqual(task.terminationStatus, 0, @"%@: the child test failed:\n%@", entry, log);
        XCTAssertTrue([log containsString:@"testChildFirstVideoToolboxUseRegistersVP9]' passed"],
                      @"%@: the child test ran and passed:\n%@", entry, log);
    }
}

/// The child of the test above (it skips unless that test starts it): in a fresh process, VP9 is not
/// registered until the entry point named by FRAMEWRIGHT_B9_CHILD_ENTRY runs, and is after it.
- (void)testChildFirstVideoToolboxUseRegistersVP9 {
    const char *entry = std::getenv("FRAMEWRIGHT_B9_CHILD_ENTRY");
    const char *file = std::getenv("FRAMEWRIGHT_B9_CHILD_FILE");
    if (entry == nullptr || file == nullptr) {
        XCTSkip(@"run by testTheProberAndTheBackendRegisterTheSupplementalDecodersInAFreshProcess in a fresh process");
    }
    XCTAssertFalse(VTIsHardwareDecodeSupported(fourcc::VP9), @"a fresh process has not registered VP9 yet");
    const std::string which = entry;
    if (which == "prober") {
        apple::AppleProber prober(10);
        auto info = prober.probe(file);
        XCTAssertTrue(info.ok(), @"%s", info.ok() ? "" : info.error().description().c_str());
    } else if (which == "backend") {
        apple::AppleBackend backend;
    } else {
        apple::AppleVideoDecoder decoder(10);
        XCTAssertTrue(decoder.open(file, -1, {}).ok());
    }
    XCTAssertTrue(VTIsHardwareDecodeSupported(fourcc::VP9), @"%s registered the supplemental decoders", entry);
}

@end
