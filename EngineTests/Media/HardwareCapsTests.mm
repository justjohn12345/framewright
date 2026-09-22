#import <XCTest/XCTest.h>

#include "../../Engine/Media/HardwareCaps.h"
#include "../../Engine/Media/MediaTypes.h"

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

@end
