#import <Metal/Metal.h>
#import <VidEditEngine/VidEditEngine.h>
#import <XCTest/XCTest.h>

@interface VEEngineTests : XCTestCase
@end

@implementation VEEngineTests

- (void)testVersionMatchesFrameworkBundle {
    NSString *version = VEEngine.engineVersion;
    XCTAssertGreaterThan(version.length, 0u);
    NSBundle *bundle = [NSBundle bundleForClass:VEEngine.class];
    XCTAssertEqualObjects(version, [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
}

- (void)testFFmpegIsLoadedAndLGPL {
    // Exercises the @rpath resolution of the FFmpeg dylibs from the framework.
    XCTAssertTrue([VEEngine.ffmpegVersion hasPrefix:@"7.1"], @"%@", VEEngine.ffmpegVersion);
    XCTAssertTrue([VEEngine.ffmpegLicense containsString:@"LGPL"], @"%@", VEEngine.ffmpegLicense);
    XCTAssertFalse([VEEngine.ffmpegLicense containsString:@"nonfree"], @"%@", VEEngine.ffmpegLicense);
}

- (void)testPassthroughShadersAreInFrameworkLibrary {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    XCTAssertNotNil(device);
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEEngine.class] error:&error];
    XCTAssertNotNil(library, @"%@", error);

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"ve_passthrough_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"ve_passthrough_fragment"];
    XCTAssertNotNil(desc.vertexFunction);
    XCTAssertNotNil(desc.fragmentFunction);
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
}

@end
