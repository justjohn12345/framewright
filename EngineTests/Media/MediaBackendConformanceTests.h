// Backend-independent conformance suite for IMediaBackend implementations.
//
// Subclass it once per backend and override +backend:
//
//   @interface FFmpegBackendConformanceTests : MediaBackendConformanceTests
//   @end
//   @implementation FFmpegBackendConformanceTests
//   + (std::shared_ptr<ve::media::IMediaBackend>)backend { return ve::media::ffmpeg::makeFFmpegBackend(); }
//   @end
//
// Every test method of this class then runs against that backend (XCTest runs inherited test
// methods). The base class itself returns nullptr from +backend and is skipped. The hooks below
// may be overridden where a backend legitimately differs; the defaults encode the contract in
// Interfaces.h.
#pragma once

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Interfaces.h"
#include "TestMedia.h"

#include <memory>
#include <string>

@interface MediaBackendConformanceTests : XCTestCase

/// The backend under test; nullptr (the default) skips the whole class.
+ (std::shared_ptr<ve::media::IMediaBackend>)backend;

/// The backend instance for this test run (created from +backend once per test).
@property (nonatomic, readonly) std::shared_ptr<ve::media::IMediaBackend> backendUnderTest;

/// Whether decoding `codecType` is expected to use hardware. Default: HardwareCaps.
- (BOOL)expectsHardwareDecodeForCodec:(uint32_t)codecType;

/// Expected MediaInfo::container for a generated clip. Default: clip.container.
- (std::string)expectedContainerForClip:(const ve::test::TestClip &)clip;

/// Absolute path of a generated test file; records a failure and returns "" if the media
/// could not be generated.
- (std::string)pathForFile:(const std::string &)file;

@end
