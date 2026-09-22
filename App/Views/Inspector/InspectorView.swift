import CoreMedia
import SwiftUI
import VidEditEngine

/// Properties of the selected clip (or the selected media when no clip is selected).
///
/// Slider drags are coalesced into one undo step per drag; typed values apply on Return.
struct InspectorView: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Inspector")
                    .font(.headline)
                if let clip = primaryClip {
                    ClipInspector(store: store, clip: clip)
                        .id(clip.clipID)
                    if let asset = store.asset(clip.assetID) {
                        AssetDetailsView(asset: asset)
                    }
                } else if let id = store.selectedAssetID, let asset = store.asset(id) {
                    AssetDetailsView(asset: asset)
                } else {
                    Text(store.selection.count > 1 ? "\(store.selection.count) clips selected" : "Nothing selected")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Inspector")
    }

    /// The clip whose properties are shown: the only selected clip, or the video clip of a
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

/// Editable clip properties.
private struct ClipInspector: View {
    @ObservedObject var store: ProjectStore
    let clip: VEClipInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Clip") {
                row("Name", clip.name)
                row("Start", Timecode.string(clip.timelineStart, frameDuration: store.frameDuration))
                row("Duration", Timecode.string(clip.duration, frameDuration: store.frameDuration))
                if !clip.isStill {
                    row("Source In", Timecode.duration(clip.sourceIn))
                    row("Source Out", Timecode.duration(clip.sourceOut))
                    NumberField(label: "Speed %", value: clip.speed * 100, range: 1 ... 10000) { percent in
                        store.report(store.engine.setSpeed(percent / 100, forClip: clip.clipID))
                    }
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
            if clip.trackKind == .video {
                videoSection
            }
            if let audioClip = audioClip {
                AudioSection(store: store, clip: audioClip)
            }
        }
    }

    /// The clip whose audio settings are shown: this clip, or its linked audio partner.
    private var audioClip: VEClipInfo? {
        if clip.trackKind == .audio { return clip }
        if clip.linkedClipID != 0, let partner = store.clips[clip.linkedClipID], partner.trackKind == .audio {
            return partner
        }
        return nil
    }

    private var videoSection: some View {
        let params = clip.videoParams
        return section("Video") {
            ParameterSlider(store: store, clipID: clip.clipID, label: "Position X", value: params.x, range: -4000 ... 4000, key: "x") { p, v in p.x = v }
            ParameterSlider(store: store, clipID: clip.clipID, label: "Position Y", value: params.y, range: -4000 ... 4000, key: "y") { p, v in p.y = v }
            ParameterSlider(store: store, clipID: clip.clipID, label: "Scale %", value: params.scale * 100, range: 1 ... 800, key: "scale") { p, v in
                p.scale = v / 100
            }
            ParameterSlider(store: store, clipID: clip.clipID, label: "Rotation °", value: params.rotationDegrees, range: -360 ... 360, key: "rotation") { p, v in
                p.rotationDegrees = v
            }
            ParameterSlider(store: store, clipID: clip.clipID, label: "Opacity %", value: params.opacity * 100, range: 0 ... 100, key: "opacity") { p, v in
                p.opacity = v / 100
            }
            Button("Reset") {
                store.report(store.engine.setVideoParams(VEVideoParamsIdentity(), forClip: clip.clipID))
            }
            .controlSize(.small)
        }
    }
}

/// A slider plus a numeric field for one video parameter. Dragging the slider is one undo step.
private struct ParameterSlider: View {
    @ObservedObject var store: ProjectStore
    let clipID: VEClipID
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let key: String
    let apply: (inout VEVideoParams, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            NumberField(label: label, value: value, range: range) { set($0) }
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range) { editing in
                if editing {
                    store.engine.beginCoalescing(withKey: "inspector.\(key).\(clipID)")
                } else {
                    store.engine.endCoalescing()
                }
            }
            .controlSize(.mini)
        }
    }

    private func set(_ newValue: Double) {
        guard let current = store.clips[clipID] else { return }
        var params = current.videoParams
        apply(&params, min(range.upperBound, max(range.lowerBound, newValue)))
        store.report(store.engine.setVideoParams(params, forClip: clipID))
    }
}

/// Gain and fades of an audio clip.
private struct AudioSection: View {
    @ObservedObject var store: ProjectStore
    let clip: VEClipInfo

    var body: some View {
        let params = clip.audioParams
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio").font(.subheadline.weight(.semibold))
            NumberField(label: "Gain dB", value: params.gainDb, range: -60 ... 24) { update { $0.gainDb = $1 }($0) }
            Slider(value: Binding(get: { params.gainDb }, set: { update { $0.gainDb = $1 }($0) }), in: -60 ... 24) { editing in
                if editing {
                    store.engine.beginCoalescing(withKey: "inspector.gain.\(clip.clipID)")
                } else {
                    store.engine.endCoalescing()
                }
            }
            .controlSize(.mini)
            NumberField(label: "Fade In s", value: params.fadeInDuration.secondsOrZero, range: 0 ... clip.duration.secondsOrZero) {
                update { $0.fadeInDuration = store.frameTime($1) }($0)
            }
            NumberField(label: "Fade Out s", value: params.fadeOutDuration.secondsOrZero, range: 0 ... clip.duration.secondsOrZero) {
                update { $0.fadeOutDuration = store.frameTime($1) }($0)
            }
        }
    }

    private func update(_ change: @escaping (inout VEAudioParams, Double) -> Void) -> (Double) -> Void {
        { value in
            guard let current = store.clips[clip.clipID] else { return }
            var params = current.audioParams
            change(&params, value)
            store.report(store.engine.setAudioParams(params, forClip: clip.clipID))
        }
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

/// A labelled number field that applies its value on Return.
struct NumberField: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .focused($focused)
                .onSubmit(apply)
                .onAppear { text = format(value) }
                .onChange(of: value) { _, newValue in
                    if !focused { text = format(newValue) }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { text = format(value) }
                }
        }
        .font(.caption)
    }

    private func apply() {
        guard let parsed = Double(text.replacingOccurrences(of: ",", with: ".")), parsed.isFinite else {
            text = format(value)
            return
        }
        commit(min(range.upperBound, max(range.lowerBound, parsed)))
    }

    private func format(_ v: Double) -> String {
        abs(v - v.rounded()) < 1e-9 ? String(format: "%.0f", v) : String(format: "%.2f", v)
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
