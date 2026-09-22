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
#include <vector>

@interface MediaBackendConformanceTests : XCTestCase

/// The backend under test; nullptr (the default) skips the whole class.
+ (std::shared_ptr<ve::media::IMediaBackend>)backend;

/// The backend instance for this test run (created from +backend once per test).
@property (nonatomic, readonly) std::shared_ptr<ve::media::IMediaBackend> backendUnderTest;

/// Whether decoding `codecType` is expected to use hardware. Default: HardwareCaps.
- (BOOL)expectsHardwareDecodeForCodec:(uint32_t)codecType;

/// Expected MediaInfo::container for a generated clip. Default: clip.container.
- (std::string)expectedContainerForClip:(const ve::test::TestClip &)clip;

/// The clips the suite runs over. Default: testClips(). Override to leave out clips the backend
/// legitimately does not handle (the router sends them to another backend) or to substitute
/// copies re-muxed into another container (then also override -pathForFile: and set
/// TestClip::container).
- (std::vector<ve::test::TestClip>)clips;

/// The clip of -clips named `file`, else the one whose name matches without the extension (so
/// the tests that name specific files follow re-muxed substitutes); nullptr if there is none.
- (const ve::test::TestClip *)clipNamed:(const std::string &)file;

/// Absolute path of a generated test file; records a failure and returns "" if the media
/// could not be generated.
- (std::string)pathForFile:(const std::string &)file;

@end
