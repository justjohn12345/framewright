import FramewrightEngine
import UniformTypeIdentifiers
import XCTest
@testable import Framewright

/// The Colour tab's LUTs (`GradeToolsModel`): a .cube file imported into the input slot or the look of the
/// selected clips (one undo step each), the names shown, "mixed" across clips, the look's strength as a drag,
/// removing, and a file that is not a LUT refused with its reason in the status line.
@MainActor
final class LUTSectionTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var tools: GradeToolsModel { store.gradeTools }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("luts")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    /// A 3D LUT of `size` per side halving every channel, written into the fixture's directory.
    private func writeCube(named name: String, title: String, size: Int = 3) throws -> URL {
        var text = "TITLE \"\(title)\"\nLUT_3D_SIZE \(size)\n"
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    let last = Double(size - 1)
                    text += "\(Double(r) / last * 0.5) \(Double(g) / last * 0.5) \(Double(b) / last * 0.5)\n"
                }
            }
        }
        let url = fixture.directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testImportingSettingAndRemovingLUTs() async throws {
        XCTAssertEqual(LUTSection.cubeType.preferredFilenameExtension, "cube")
        let (movie, _) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 1)
        store.selection = [first]
        XCTAssertTrue(tools.importLUT(at: try writeCube(named: "half.cube", title: "Half"), into: .input))
        XCTAssertEqual(store.undoActionName, "Change Input LUT")
        let id = tools.lut(.input).id
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(tools.lutName(id), "Half")
        XCTAssertEqual(tools.lutName(""), "None")
        XCTAssertEqual(store.clips[first]?.gradeInputLUTID, id)

        // Two clips: the input differs ("mixed"); a look set on both; its strength dragged on both.
        store.selection = [first, second]
        XCTAssertTrue(tools.lut(.input).mixed)
        XCTAssertTrue(tools.importLUT(at: try writeCube(named: "look.cube", title: "Look", size: 5), into: .look))
        XCTAssertFalse(tools.lut(.look).mixed)
        XCTAssertEqual(tools.lookStrength.value, 1)
        tools.beginStrengthDrag()
        for strength in [0.9, 0.7, 0.55] {
            tools.setLookStrength(strength)
        }
        tools.endDrag()
        XCTAssertEqual(store.clips[second]?.gradeLookStrength, 0.55)
        XCTAssertEqual(store.undoActionName, "Change Look Strength")
        store.undo()
        XCTAssertEqual(store.clips[second]?.gradeLookStrength, 1, "the drag was one undo step")
        store.redo()
        tools.setLookStrength(7)
        XCTAssertEqual(store.clips[first]?.gradeLookStrength, 1, "limited to 0...1")
        // Removing: the input from both, then the look (its strength back to 1).
        tools.setLUT("", .input)
        XCTAssertEqual(store.clips[first]?.gradeInputLUTID, "")
        tools.setLUT("", .look)
        XCTAssertFalse(store.clips[second]?.hasGrade ?? true)
        XCTAssertEqual(tools.lookStrength.value, 1)
    }

    func testAFileThatIsNotALUTIsRefused() async throws {
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = [clip]
        let url = fixture.directory.appendingPathComponent("broken.cube")
        try "LUT_3D_SIZE 2\n0 0 0\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(tools.importLUT(at: url, into: .look))
        XCTAssertEqual(store.statusMessage,
                       "“broken.cube” is not a LUT Framewright can use: the table has 1 values; LUT_3D_SIZE 2 needs 8")
        XCTAssertEqual(store.clips[clip]?.gradeLookLUTID, "")
        XCTAssertFalse(tools.importLUT(at: fixture.directory.appendingPathComponent("missing.cube"), into: .input))
        XCTAssertTrue(store.statusMessage?.contains("cannot be read") ?? false)
    }
}
