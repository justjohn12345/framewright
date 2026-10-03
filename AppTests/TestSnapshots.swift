import AppKit
import XCTest

/// Offscreen drawings of hosted views written as PNG files for a person to look at, when the environment asks for
/// them (FW_SNAPSHOTS=1; with xcodebuild, TEST_RUNNER_FW_SNAPSHOTS=1): never a capture of the screen, only what a view
/// draws (`HostedView.bitmap()`). They go to "FramewrightSnapshots" in the test host's temporary directory (the app's
/// sandbox container), whose path is logged. Without the variable nothing is written.
enum TestSnapshots {
    static var directory: URL? {
        guard ProcessInfo.processInfo.environment["FW_SNAPSHOTS"] == "1" else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("FramewrightSnapshots", isDirectory: true)
    }

    /// Writes `bitmap` as `<name>.png` in the snapshot directory, if there is one.
    static func write(_ bitmap: NSBitmapImageRep?, name: String) {
        guard let directory, let bitmap, let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".png")
        do {
            try png.write(to: url)
            print("[snapshot] \(url.path)")
        } catch {
            print("[snapshot] \(name) not written: \(error)")
        }
    }
}
