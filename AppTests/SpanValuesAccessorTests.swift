import FramewrightEngine
import XCTest

/// `VESpanValues` read and written by `VESpanParameter` (colour grading prerequisites, item 3): the
/// accessors reach the same fields as the named ones, for every parameter, as Swift sees them.
final class SpanValuesAccessorTests: XCTestCase {
    private let fields: [(VESpanParameter, WritableKeyPath<VESpanValues, Double>)] = [
        (.positionX, \.x), (.positionY, \.y), (.scale, \.scale), (.rotation, \.rotationDegrees),
        (.opacity, \.opacity), (.gain, \.gainDb),
    ]

    func testEachParameterReadsAndWritesItsOwnField() {
        for (index, (parameter, field)) in fields.enumerated() {
            var values = VESpanValuesUnchanged()
            XCTAssertTrue(values.value(for: parameter).isNaN)
            let value = Double(index) + 0.25
            values.setValue(value, for: parameter)
            XCTAssertEqual(values[keyPath: field], value, "\(parameter.rawValue)")
            XCTAssertEqual(values.value(for: parameter), value)
            for (other, otherField) in fields where other != parameter {
                XCTAssertTrue(values[keyPath: otherField].isNaN, "\(other.rawValue) changed with \(parameter.rawValue)")
            }
            values[keyPath: field] = -value
            XCTAssertEqual(values.value(for: parameter), -value)
        }
    }
}
