import Foundation
import XCTest

/// UserDefaults suites for tests. AppTests run inside the app (same bundle id), so a suite named like a
/// domain is a plist in the app's own container (review B8: about 3,000 had piled up there), and removing
/// the domain does not remove the file reliably (cfprefsd may write the removal as an empty plist, at once,
/// later or when the process exits). A suite named by an absolute path keeps its plist at that path
/// instead: here in a directory of the test's own, removed with everything in it when the test ends (a
/// write cfprefsd makes after that finds no directory and creates nothing; measured, also at exit).
extension XCTestCase {
    /// A fresh, empty suite, removed with its plist when the test ends.
    func makeTestDefaults(_ prefix: String, file: StaticString = #filePath, line: UInt = #line) throws -> UserDefaults {
        try makeTestDefaultsSuite(prefix, file: file, line: line).defaults
    }

    /// The same, with the suite's name (for a second instance of the suite, as another thread uses).
    func makeTestDefaultsSuite(_ prefix: String, file: StaticString = #filePath,
                               line: UInt = #line) throws -> (name: String, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramewrightTestDefaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = directory.appendingPathComponent(prefix).path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name), "UserDefaults suite \(name)", file: file, line: line)
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        return (name, defaults)
    }
}
