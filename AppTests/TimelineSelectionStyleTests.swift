import SwiftUI
import XCTest
@testable import Framewright

/// The timeline's selection style (hands-on round, 2026-09-27: selected items were hard to see): clips,
/// span bars and transition bars all get, when selected, a fill 20 % lighter than their unselected fill,
/// opaque, a 2 pt border in the accent colour inside the item, and a label colour that reads on that
/// fill; unselected they keep their fill, hairline and white label.
@MainActor
final class TimelineSelectionStyleTests: XCTestCase {
    func testEveryKindIsLighterWithAnAccentBorderInsideWhenSelected() {
        XCTAssertEqual(TimelineItemStyle.Kind.allCases.count, 8)
        for kind in TimelineItemStyle.Kind.allCases {
            let plain = TimelineRenderer.style(for: kind, selected: false)
            let selected = TimelineRenderer.style(for: kind, selected: true)
            let base = TimelineItemStyle.baseFill(kind)
            let name = String(describing: kind)

            XCTAssertEqual(plain.fill, base, name)
            XCTAssertEqual(plain.fillOpacity, 0.85, name)
            XCTAssertNotEqual(plain.border, .accent, name)
            XCTAssertEqual(plain.borderInset, 0, "\(name): the hairline stays on the edge")
            XCTAssertEqual(plain.label, .white, name)

            // 20 % lighter: each component a fifth of the way to white.
            XCTAssertEqual(selected.fill.red, base.red + (1 - base.red) * 0.2, accuracy: 1e-12, name)
            XCTAssertEqual(selected.fill.green, base.green + (1 - base.green) * 0.2, accuracy: 1e-12, name)
            XCTAssertEqual(selected.fill.blue, base.blue + (1 - base.blue) * 0.2, accuracy: 1e-12, name)
            XCTAssertGreaterThan(selected.fill.luminance, plain.fill.luminance, name)
            XCTAssertEqual(selected.fillOpacity, 1, name)
            XCTAssertEqual(selected.border, .accent, name)
            XCTAssertEqual(selected.borderColor, Color.accentColor, name)
            XCTAssertEqual(selected.borderWidth, 2, name)
            XCTAssertEqual(selected.borderInset, 1, "\(name): the whole 2 pt border lies inside the item")
            // The label reads on the brighter fill (WCAG AA for small text).
            XCTAssertGreaterThanOrEqual(selected.fill.contrast(with: selected.label), 4.5, name)
        }
        // Span bars and transition bars take their kind's style; the Effects tab's colours are the same fills.
        XCTAssertEqual(TimelineItemStyle.Kind(TimelineViewModel.SpanKind.transition), .transition)
        XCTAssertEqual(TimelineItemStyle.Kind(TimelineViewModel.SpanKind.motion), .motion)
        XCTAssertEqual(TimelineItemStyle.Kind(TimelineViewModel.SpanKind.opacity), .opacity)
        XCTAssertEqual(TimelineItemStyle.Kind(TimelineViewModel.SpanKind.gain), .gain)
        XCTAssertEqual(TimelineRenderer.color(.motion), TimelineItemStyle.baseFill(.motion).color)
    }

    func testContrastIsTheWCAGRatio() {
        XCTAssertEqual(TimelineItemStyle.RGB.white.contrast(with: .black), 21, accuracy: 1e-9)
        XCTAssertEqual(TimelineItemStyle.RGB.white.luminance, 1, accuracy: 1e-12)
        XCTAssertEqual(TimelineItemStyle.RGB(red: 0.5, green: 0.5, blue: 0.5).luminance, 0.214041, accuracy: 1e-6)
    }
}
