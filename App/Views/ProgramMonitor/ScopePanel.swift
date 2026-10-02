import FramewrightEngine
import SwiftUI

/// The clipped shares the scope view publishes, for the panel's indicator (only the panel redraws when
/// they change, at most ten times a second).
@MainActor
final class ScopeClippingModel: ObservableObject {
    @Published private(set) var highlights: Double = 0
    @Published private(set) var shadows: Double = 0

    func update(highlights newHighlights: Double, shadows newShadows: Double) {
        if highlights != newHighlights { highlights = newHighlights }
        if shadows != newShadows { shadows = newShadows }
    }
}

/// The program monitor's scopes (View > Show Scopes), beside or below the program monitor (`ScopeLayout`):
/// a header with the scope menu (Waveform, Histogram, Vectorscope), the histogram's style, the clipping indicator, the
/// monitor's clipping overlay, the placement menu and the close button; under it the scope, at the
/// picture's aspect, with the waveform's IRE scale on its left. The engine draws the scope with every frame
/// the program monitor shows (`VEWaveformView`), so it follows the playhead and plays along, showing the
/// graded picture; SwiftUI only lays it out (and redraws the indicator when the clipped shares change).
struct ScopePanel: View {
    let store: ProjectStore
    @ObservedObject var layout: WindowLayoutModel
    @StateObject private var clipping = ScopeClippingModel()

    init(store: ProjectStore) {
        self.store = store
        layout = store.layout
    }

    /// The picture's aspect (the sequence's), which the scope keeps.
    private var aspect: CGFloat {
        let sequence = store.sequence
        return sequence.width > 0 && sequence.height > 0 ? CGFloat(sequence.width) / CGFloat(sequence.height) : 16.0 / 9.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: ScopeLayout.headerHeight)
            HStack(alignment: .top, spacing: 0) {
                scale
                    .frame(width: ScopeLayout.scaleWidth)
                WaveformViewRepresentable(attach: { store.attachWaveformView($0) },
                                          detach: { store.detachWaveformView($0) },
                                          mode: layout.scopeMode.engineMode,
                                          histogramStyle: layout.histogramStyle.engineStyle,
                                          onClipping: { [weak clipping] highlights, shadows in
                                              clipping?.update(highlights: highlights, shadows: shadows)
                                          })
                    .aspectRatio(aspect, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityIdentifier("Waveform")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("Scope", selection: $layout.scopeMode) {
                ForEach(ScopeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("The scope: luma per picture column, how many pixels have each level, or their colours (chroma)")
            .accessibilityIdentifier("ScopeMode")
            if layout.scopeMode == .histogram {
                Picker("Histogram", selection: $layout.histogramStyle) {
                    ForEach(HistogramStyleChoice.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("HistogramStyle")
            }
            Spacer(minLength: 4)
            ScopeClippingIndicator(clipping: clipping)
            Button {
                layout.showsClippingOverlay.toggle()
            } label: {
                Image(systemName: layout.showsClippingOverlay ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(layout.showsClippingOverlay ? "Hide the clipping on the program monitor"
                : "Show the clipping on the program monitor: red where a channel is at 100 %, blue where one is at 0 %")
            .accessibilityIdentifier("ClippingOverlay")
            Menu {
                Picker("Placement", selection: $layout.scopePlacement) {
                    ForEach(ScopePlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Where the scopes sit")
            .accessibilityIdentifier("ScopePlacement")
            Button {
                store.setWaveformVisible(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Hide the scopes")
            .accessibilityIdentifier("HideWaveform")
        }
        .padding(.leading, ScopeLayout.scaleWidth)
    }

    /// The waveform's 100, 50 and 0 IRE beside the graticule's brighter lines; nothing for the other scopes.
    private var scale: some View {
        GeometryReader { area in
            if layout.scopeMode == .waveform {
                ForEach([100, 50, 0], id: \.self) { ire in
                    Text("\(ire)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: area.size.width / 2,
                                  y: min(max(5, area.size.height * CGFloat(100 - ire) / 100), area.size.height - 5))
                }
            }
        }
    }
}

/// Slice 1's name for the scope panel.
typealias WaveformPanel = ScopePanel

/// The share of the picture's pixels with a channel at or above 100 % (highlights, red when any) and at or
/// below 0 % (shadows, blue when any).
struct ScopeClippingIndicator: View {
    @ObservedObject var clipping: ScopeClippingModel

    var body: some View {
        HStack(spacing: 6) {
            Label(ScopeLayout.clippingText(clipping.shadows), systemImage: "arrowtriangle.down.fill")
                .foregroundStyle(clipping.shadows > 0 ? Color.blue : Color.secondary)
                .help("Shadows: \(ScopeLayout.clippingText(clipping.shadows)) of the pixels have a channel at or below 0 %")
                .accessibilityIdentifier("ClippedShadows")
            Label(ScopeLayout.clippingText(clipping.highlights), systemImage: "arrowtriangle.up.fill")
                .foregroundStyle(clipping.highlights > 0 ? Color.red : Color.secondary)
                .help("Highlights: \(ScopeLayout.clippingText(clipping.highlights)) of the pixels have a channel at or above 100 %")
                .accessibilityIdentifier("ClippedHighlights")
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}
