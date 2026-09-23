import VidEditEngine
import XCTest
@testable import VidEdit

@MainActor
final class ContentViewTests: XCTestCase {
    func testVersionTextReportsEngineAndFFmpegVersions() {
        let text = ContentView.versionText
        XCTAssertEqual(text, "Engine \(VEEngine.engineVersion) · FFmpeg \(VEEngine.ffmpegVersion)")
        XCTAssertFalse(VEEngine.engineVersion.isEmpty)
        XCTAssertTrue(VEEngine.ffmpegVersion.hasPrefix("7.1"), VEEngine.ffmpegVersion)
    }

    func testRunsInsideSandboxedHostApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.justjohn12345.videdit")
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"],
            "host app should run with the App Sandbox enabled"
        )
    }

    /// The licence texts and notices ship in the app and are what the Acknowledgements window
    /// shows (LGPL compliance for the bundled FFmpeg dylibs).
    func testAcknowledgementsAndTheLGPLAreBundled() throws {
        for name in AcknowledgementsView.resourceNames {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: nil), "\(name) is bundled")
        }
        let text = AcknowledgementsView.text()
        for needle in ["GNU LESSER GENERAL PUBLIC LICENSE", "Version 2.1, February 1999", "FFmpeg 7.1.5",
                       "--disable-gpl --disable-nonfree", "Scripts/build-ffmpeg.sh", "corresponding source code",
                       "dav1d", "SVT-AV1", "Alliance for Open Media Patent License", "nlohmann/json", "doctest"] {
            XCTAssertTrue(text.contains(needle), "the acknowledgements mention \(needle)")
        }
        XCTAssertFalse(text.contains("is missing from the application bundle"))
    }
}
