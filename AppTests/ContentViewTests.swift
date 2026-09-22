import VidEditEngine
import XCTest
@testable import VidEdit

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
}
