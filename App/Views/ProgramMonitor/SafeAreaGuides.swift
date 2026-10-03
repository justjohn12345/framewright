import SwiftUI

/// The program monitor's safe-area guides (View > Show Title/Action Safe Areas; `SafeAreas`): the action-safe
/// rectangle, the title-safe rectangle inside it and a cross at the frame's centre, thin and translucent over the
/// picture (each line drawn light over a dark one, so it shows over any picture). Drawing only: presses go through.
struct SafeAreaGuides: View {
    let areas: SafeAreas
    let viewport: KenBurnsViewport

    /// The centre cross's arm, as a fraction of the frame's height.
    static let crossFraction: CGFloat = 0.025

    var body: some View {
        let action = rect(areas.action)
        let title = rect(areas.title)
        let centre = viewport.view(areas.centre)
        let arm = max(4, areas.frame.height * Self.crossFraction * viewport.scale)
        let guides = Path { path in
            path.addRect(action)
            path.addRect(title)
            path.move(to: CGPoint(x: centre.x - arm, y: centre.y))
            path.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
            path.move(to: CGPoint(x: centre.x, y: centre.y - arm))
            path.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
        }
        ZStack {
            guides.stroke(Color.black.opacity(0.45), lineWidth: 2)
            guides.stroke(Color.white.opacity(0.7), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("SafeAreaGuides")
    }

    private func rect(_ rect: CGRect) -> CGRect {
        let origin = viewport.view(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * viewport.scale, height: rect.height * viewport.scale)
    }
}
