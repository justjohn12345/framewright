import SwiftUI

/// The program monitor's zoom pop-up, above the monitor at its right (Final Cut's viewer zoom menu): Fit and the
/// fixed levels (`ProgramZoom.levels`), Zoom In and Zoom Out. Its label is the level chosen ("Fit", "50 %").
/// The keys (Command-plus, Command-minus, Shift-Z for Fit) work while the monitor has the focus
/// (`ProjectStore.focusProgramMonitor`); the menu shows them.
struct ProgramZoomControl: View {
    @ObservedObject var zoom: ProgramMonitorZoom

    var body: some View {
        Menu {
            Button("Fit  ⇧Z") { zoom.fit() }
                .accessibilityIdentifier("ProgramZoom.fit")
            Divider()
            ForEach(ProgramZoom.levels, id: \.self) { level in
                Button("\(level) %") { zoom.zoom = .percent(level) }
                    .accessibilityIdentifier("ProgramZoom.\(level)")
            }
            Divider()
            Button("Zoom In  ⌘+") { zoom.zoomIn() }
            Button("Zoom Out  ⌘−") { zoom.zoomOut() }
        } label: {
            Text(zoom.zoom.title)
                .font(.caption)
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Zoom the program monitor: Fit shows the whole frame (and the Ken Burns boxes); 100 % is one pixel of "
            + "the sequence per pixel of the screen. ⌘+ and ⌘− zoom, ⇧Z fits, while the monitor has the focus "
            + "(click it).")
        .accessibilityIdentifier("ProgramZoom")
    }
}
