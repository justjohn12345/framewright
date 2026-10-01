// The EngineTests scratch directories (TestMedia.h scratchDirectory()) are removed when the test that made
// them ends (review B8 of the 2026-10-01 general review: runs had left 28,874 directories, 7.1 GB, in
// $TMPDIR/FramewrightEngineTests).

#import <XCTest/XCTest.h>

#include "TestMedia.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

namespace {

bool keepsScratch() {
    const char *keep = std::getenv("FRAMEWRIGHT_KEEP_TEST_SCRATCH");
    return keep != nullptr && *keep != '\0' && std::string(keep) != "0";
}

/// The directory testAAMakesAScratchDirectory made (XCTest runs a class's tests in name order).
std::string &madeByTheTestBefore() {
    static std::string directory;
    return directory;
}

} // namespace

@interface ScratchDirectoryTests : XCTestCase
@end

@implementation ScratchDirectoryTests

- (void)testAAMakesAScratchDirectory {
    const std::string dir = ve::test::scratchDirectory();
    std::ofstream(dir + "/file.bin") << "some bytes";
    XCTAssertTrue(std::filesystem::exists(dir + "/file.bin"));
    madeByTheTestBefore() = dir;
}

- (void)testABTheDirectoryTheTestBeforeMadeIsGone {
    if (madeByTheTestBefore().empty()) {
        XCTSkip(@"run with testAAMakesAScratchDirectory, which runs first");
    }
    if (keepsScratch()) {
        XCTSkip(@"FRAMEWRIGHT_KEEP_TEST_SCRATCH keeps the scratch directories");
    }
    XCTAssertFalse(std::filesystem::exists(madeByTheTestBefore()), @"%s", madeByTheTestBefore().c_str());
}

- (void)testRemovingTheScratchDirectoriesDeletesTheirFiles {
    if (keepsScratch()) {
        XCTSkip(@"FRAMEWRIGHT_KEEP_TEST_SCRATCH keeps the scratch directories");
    }
    const std::string dir = ve::test::scratchDirectory();
    std::filesystem::create_directories(dir + "/nested");
    std::ofstream(dir + "/nested/file.bin") << "some bytes";
    ve::test::removeScratchDirectories();
    XCTAssertFalse(std::filesystem::exists(dir));
}

@end
