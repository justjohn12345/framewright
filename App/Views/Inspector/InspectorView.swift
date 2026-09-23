import CoreMedia
import SwiftUI
import FramewrightEngine

/// Properties of the selection: the selected clips' video and audio parameters (multi-selection
/// edits apply to every selected clip of the matching kind), a single clip's speed, the selected
/// transition, or the selected media.
///
/// Every parameter can be dragged (slider: one undo step per drag), typed with or without its
/// unit (Return applies it, clamped to the parameter's range) and nudged from its field with
/// Up/Down (±1) and Shift+Up/Down (±10; a burst of nudges is one undo step). Each parameter and
/// each section has a reset button. Refused edits show a message at the top (see
/// `InspectorModel`, which holds the logic).
struct InspectorView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var inspector: InspectorModel

    init(store: ProjectStore) {
        self.store = store
        inspector = store.inspector
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let message = inspector.message {
                    InspectorMessage(text: message) { inspector.clearMessage() }
                }
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Inspector")
        .onDisappear {
            inspector.endSliderDrag()
            inspector.endNudgeBurst()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let transition = inspector.transition {
            TransitionInspector(store: store, inspector: inspector, transition: transition)
        } else if !store.selection.isEmpty {
            if let clip = primaryClip {
                ClipInfoSection(store: store, clip: clip)
            } else {
                Text("\(store.selection.count) clips selected")
                    .foregroundStyle(.secondary)
                Divider()
            }
            if inspector.isAvailable(.positionX) {
                ParameterSection(store: store, inspector: inspector, section: .video,
                                 subtitle: inspector.videoTargets.count > 1 ? "\(inspector.videoTargets.count) video clips" : nil)
            }
            if inspector.isAvailable(.gain) {
                ParameterSection(store: store, inspector: inspector, section: .audio,
                                 subtitle: inspector.audioTargets.count > 1 ? "\(inspector.audioTargets.count) audio clips" : nil)
            }
            speedSection
            if let clip = primaryClip, let asset = store.asset(clip.assetID) {
                AssetDetailsView(asset: asset)
            }
        } else if let id = store.selectedAssetID, let asset = store.asset(id) {
            AssetDetailsView(asset: asset)
        } else {
            Text("Nothing selected")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var speedSection: some View {
        let movable = store.selectedClips.contains { !$0.isStill }
        if inspector.isAvailable(.speed) {
            ParameterSection(store: store, inspector: inspector, section: .speed, subtitle: nil) {
                speedButton
            }
        } else if movable {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speed").font(.subheadline.weight(.semibold))
                speedButton
            }
            Divider()
        }
    }

    private var speedButton: some View {
        Button("Speed/Duration…") { store.showSpeedSheet() }
            .controlSize(.small)
            .help("Change the speed of the selected clips (⌘R)")
    }

    /// The clip whose details are shown: the only selected clip, or the video clip of a
    /// selected linked pair.
    private var primaryClip: VEClipInfo? {
        let selected = store.selectedClips
        if selected.count == 1 { return selected[0] }
        if selected.count == 2, selected[0].linkedClipID == selected[1].clipID {
            return selected.first { $0.trackKind == .video } ?? selected[0]
        }
        return nil
    }
}

/// A non-modal message (a refused edit, a limit that was applied) with a close button.
private struct InspectorMessage: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Dismiss")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("InspectorMessage")
    }
}

/// Read-only facts about a clip, and Link/Unlink.
private struct ClipInfoSection: View {
    @ObservedObject var store: ProjectStore
    let clip: VEClipInfo

    var body: some View {
        section("Clip") {
            row("Name", clip.name)
            row("Start", Timecode.string(clip.timelineStart, frameDuration: store.frameDuration))
            row("Duration", store.durationString(frames: store.frames(clip.duration)))
            if !clip.isStill {
                row("Source In", Timecode.duration(clip.sourceIn))
                row("Source Out", Timecode.duration(clip.sourceOut))
            }
            HStack {
                Text(clip.linkedClipID != 0 ? "Linked" : "Not linked")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(clip.linkedClipID != 0 ? "Unlink" : "Link Selected") {
                    store.linkOrUnlinkSelection()
                }
                .controlSize(.small)
            }
        }
    }
}

/// A section of parameters with a reset button for the whole section.
private struct ParameterSection<Extra: View>: View {
    @ObservedObject var store: ProjectStore
    let inspector: InspectorModel
    let section: InspectorSection
    let subtitle: String?
    let extra: Extra

    init(store: ProjectStore, inspector: InspectorModel, section: InspectorSection, subtitle: String?,
         @ViewBuilder extra: () -> Extra) {
        self.store = store
        self.inspector = inspector
        self.section = section
        self.subtitle = subtitle
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { inspector.reset(section) }
                    .controlSize(.small)
                    .help("Reset every \(section.title.lowercased()) setting of the selection")
                    .accessibilityIdentifier("Reset.\(section.rawValue)")
            }
            ForEach(InspectorParameter.parameters(in: section)) { parameter in
                ParameterRow(store: store, inspector: inspector, parameter: parameter)
            }
            extra
        }
        Divider()
    }
}

extension ParameterSection where Extra == EmptyView {
    init(store: ProjectStore, inspector: InspectorModel, section: InspectorSection, subtitle: String?) {
        self.init(store: store, inspector: inspector, section: section, subtitle: subtitle) { EmptyView() }
    }
}

/// One parameter: label, typed field (with nudges), reset button and slider.
private struct ParameterRow: View {
    @ObservedObject var store: ProjectStore
    let inspector: InspectorModel
    let parameter: InspectorParameter
    var focusSerial = 0
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(parameter.label)
                    .foregroundStyle(.secondary)
                Spacer()
                NumericField(text: inspector.text(parameter),
                             placeholder: inspector.isMixed(parameter) ? "Mixed" : "",
                             commit: { inspector.commitText(parameter, $0) },
                             nudge: { inspector.nudge(parameter, steps: $0) },
                             focusSerial: focusSerial,
                             accessibilityIdentifier: "Parameter.\(parameter.rawValue)")
                    .frame(width: 104, height: 20)
                Button {
                    inspector.reset(parameter)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reset \(parameter.label)")
            }
            .font(.caption)
            Slider(value: Binding(get: { inspector.value(parameter) ?? parameter.defaultValue },
                                  set: { inspector.sliderChanged(parameter, $0) }),
                   in: inspector.sliderRange(parameter)) { editing in
                if editing {
                    inspector.beginSliderDrag(parameter)
                    dragging = true
                } else {
                    inspector.endSliderDrag()
                    dragging = false
                }
            }
            .controlSize(.mini)
        }
        .onDisappear {
            // The selection changed mid-drag: commit what the drag did.
            if dragging {
                dragging = false
                inspector.endSliderDrag()
            }
        }
    }
}

/// The selected transition: kind, alignment, where it sits on its cut, its duration (bounded by
/// the cut's media) and, for a dissolve with its linked crossfade (or the other way round),
/// whether a duration change also changes the linked one and which of them Delete removes.
private struct TransitionInspector: View {
    @ObservedObject var store: ProjectStore
    let inspector: InspectorModel
    let transition: VETransitionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transition").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { inspector.reset(.transition) }
                    .controlSize(.small)
                    .help("Back to the default duration (Settings > Editing)")
            }
            row("Kind", inspector.transitionKind?.title ?? "Cross Dissolve")
            row("Alignment", "Centred on cut")
            if let timing = inspector.transitionTiming {
                HStack(alignment: .firstTextBaseline) {
                    Text(timing.cutText(frameDuration: store.frameDuration))
                        .accessibilityIdentifier("TransitionCut")
                    Spacer()
                    Text(timing.offsetsText(frameDuration: store.frameDuration,
                                            display: store.editingPreferences.durationDisplay))
                        .foregroundStyle(.secondary)
                        .help("How far the transition reaches before and after the cut")
                        .accessibilityIdentifier("TransitionOffsets")
                }
                .font(.caption.monospacedDigit())
            }
            ParameterRow(store: store, inspector: inspector, parameter: .transitionDuration,
                         focusSerial: focusSerial)
            let linked = inspector.linkedTransition
            if linked != nil {
                Toggle("Also change the linked transition",
                       isOn: Binding(get: { store.resizesLinkedTransitions },
                                     set: { store.resizesLinkedTransitions = $0 }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("A duration change here or by dragging a handle also changes the "
                        + (inspector.transitionKind == .crossDissolve ? "linked audio crossfade" : "linked video dissolve"))
                    .accessibilityIdentifier("ResizeLinkedTransition")
            }
            if let limit = inspector.transitionLimit {
                Text("At most \(store.durationString(frames: limit.maximumFrames)): \(limit.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(linked != nil ? "Delete Both" : "Delete Transition") {
                    inspector.deleteTransition()
                }
                .help(linked != nil ? "Delete this transition and its linked one (⌫)" : "Delete the transition (⌫)")
                .accessibilityIdentifier("DeleteTransition")
                if linked != nil {
                    Button("Delete This One") {
                        inspector.deleteTransition(includingLinked: false)
                    }
                    .help("Delete only this transition, keeping the linked one (⌥⌫)")
                    .accessibilityIdentifier("DeleteTransitionOnly")
                }
            }
            .controlSize(.small)
        }
        Divider()
    }

    private var focusSerial: Int {
        guard let request = store.inspectorFocusRequest, request.field == .transitionDuration else { return 0 }
        return request.serial
    }
}

/// Read-only media details: codec, backend, hardware decode and the router's reasoning.
struct AssetDetailsView: View {
    let asset: VEAssetInfo

    var body: some View {
        section("Media") {
            row("File", asset.name)
            row("Kind", kindName)
            if asset.hasVideo {
                row("Size", "\(asset.width) × \(asset.height)")
                if !asset.isStill {
                    row("Frame rate", asset.fpsString + (asset.isVFR ? " (VFR)" : ""))
                }
            }
            if !asset.isStill {
                row("Duration", Timecode.duration(asset.duration))
            }
            row("Codec", asset.codecName.isEmpty ? "—" : asset.codecName)
            if asset.hasAudio {
                row("Audio", "\(asset.audioCodecName) \(asset.sampleRate) Hz, \(asset.channels) ch")
            }
            row("Container", asset.container.isEmpty ? "—" : asset.container)
            row("Backend", asset.backendName)
            row("Hardware decode", asset.hardwareDecode ? "Yes" : "No")
            if asset.isMissing {
                Label("File not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            if !asset.routingReason.isEmpty {
                Text(asset.routingReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var kindName: String {
        switch asset.kind {
        case .video: return "Video"
        case .audio: return "Audio"
        case .still: return "Still image"
        case .audioVideo: return "Video + audio"
        @unknown default: return "Media"
        }
    }
}

@ViewBuilder
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.subheadline.weight(.semibold))
        content()
    }
    Divider()
}

private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label).foregroundStyle(.secondary)
        Spacer()
        Text(value)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .textSelection(.enabled)
    }
    .font(.caption)
}
