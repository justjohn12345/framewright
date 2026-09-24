import CoreMedia
import SwiftUI
import FramewrightEngine

/// Properties of the selection: the selected span (an effect span's range, interpolation, lane and
/// start and end values; a transition's duration and shares of its cut), or the selected clips'
/// video and audio parameters (multi-selection edits apply to every selected clip of the matching
/// kind), a single clip's speed, or the selected media.
///
/// Every clip parameter can be dragged (slider: one undo step per drag), typed with or without its
/// unit (Return applies it, clamped to the parameter's range) and nudged from its field with
/// Up/Down (±1) and Shift+Up/Down (±10; a burst of nudges is one undo step). Each parameter and
/// each section has a reset button. The Video values are the clip's static values (what its effect
/// spans compose onto; they do not follow the playhead). A span's fields work the same way (typed,
/// nudged); its values are what its start and end show (see `InspectorModel`). Refused edits show a
/// message at the top (see `InspectorModel`, which holds the logic).
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
        if let span = inspector.span {
            SpanInspector(store: store, inspector: inspector, span: span)
        } else if let transition = inspector.transition {
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
                                 subtitle: inspector.videoTargets.count > 1 ? "\(inspector.videoTargets.count) video clips" : nil) {
                    if let note = spanNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("VideoSpansNote")
                    }
                    if inspector.motionTarget != nil {
                        HStack {
                            matchMenu
                            Spacer()
                        }
                    }
                }
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

    /// Says that the clips' effect spans compose onto the static values shown (nil when none has
    /// any).
    private var spanNote: String? {
        let count = inspector.videoTargets.reduce(0) { total, clip in
            total + clip.spans.filter { $0.kind == .motion || $0.kind == .opacity }.count
        }
        guard count > 0 else { return nil }
        return (count == 1 ? "1 effect span composes" : "\(count) effect spans compose")
            + " onto these values over time; select a span on the clip's lanes to edit it."
    }

    /// Match Previous Clip's End / Match Next Clip's Start (enabled next to a touching clip).
    private var matchMenu: some View {
        let previous = inspector.canMatch(.start)
        let next = inspector.canMatch(.end)
        return Menu("Match") {
            Button("Match Previous Clip's End") { inspector.matchAdjacent(.start) }
                .disabled(!previous)
                .help("Copy the position, scale, rotation and opacity of the previous clip's last frame to this clip's first frame")
            Button("Match Next Clip's Start") { inspector.matchAdjacent(.end) }
                .disabled(!next)
                .help("Copy the position, scale, rotation and opacity of the next clip's first frame to this clip's last frame")
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(!previous && !next)
        .help("Match the framing of a clip touching this one on its track")
        .accessibilityIdentifier("MatchNeighbour")
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
            // The Video rows show the clips' static values, which do not follow the playhead.
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

/// The selected transition (a lane-0 span): what it does (a cross dissolve / crossfade across the
/// cut, a fade from or to black / silence), where it sits on its cut, its duration (bounded by the
/// cut's media), the share of each side of the cut (editable, keeping the duration) and, for a
/// dissolve with its linked crossfade (or the other way round), whether a change also changes the
/// linked one and which of them Delete removes.
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
            row("Kind", kindTitle)
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
            if inspector.transitionShares != nil {
                shares
            }
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

    private var kindTitle: String {
        let audio = inspector.transitionKind == .audioCrossfade
        switch transition.style {
        case .fadeIn: return audio ? "Fade In from Silence" : "Fade In from Black"
        case .fadeOut: return audio ? "Fade Out to Silence" : "Fade Out to Black"
        default: return inspector.transitionKind?.title ?? "Cross Dissolve"
        }
    }

    /// The share of each side of the cut, in percent: typing one moves the split, keeping the
    /// duration (↑/↓ move it a frame).
    private var shares: some View {
        HStack(spacing: 4) {
            Text("Before cut").foregroundStyle(.secondary)
            NumericField(text: inspector.shareText(before: true), placeholder: "",
                         commit: { inspector.commitShare(before: true, $0) },
                         nudge: { inspector.nudgeShare(before: true, steps: $0) },
                         accessibilityIdentifier: "TransitionShareBefore")
                .frame(width: 64, height: 20)
            Spacer()
            Text("After").foregroundStyle(.secondary)
            NumericField(text: inspector.shareText(before: false), placeholder: "",
                         commit: { inspector.commitShare(before: false, $0) },
                         nudge: { inspector.nudgeShare(before: false, steps: $0) },
                         accessibilityIdentifier: "TransitionShareAfter")
                .frame(width: 64, height: 20)
        }
        .font(.caption)
        .help("How much of the transition lies before and after the cut; drag its edges on lane 0 too")
    }
}

/// The selected effect span (lanes 1-3): its kind and clip, its range (Start, End, Duration as
/// timeline times; limited to the clip and the free space of its lane, with a note), its
/// interpolation and lane, and per parameter the values its start and end show, absolute (the
/// base the rest of the clip composes to there with the span's own value on it; see
/// `InspectorModel`). Match Previous Clip's End / Match Next Clip's Start, Ken Burns… (a Motion
/// span: the editor on the program monitor) and Remove. Every value is read from the store as it is
/// now: the view observes the store, so an edit of an earlier span, an undo or a trim re-reads them.
private struct SpanInspector: View {
    @ObservedObject var store: ProjectStore
    let inspector: InspectorModel
    let span: VEEffectSpan

    private var clip: VEClipInfo? { store.clips[span.clipID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(ProjectStore.title(of: span, isAudio: false) + " Span",
                      systemImage: SpanInspector.systemImage(span.kind))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("SpanKind")
                Spacer()
                if span.kind == .motion {
                    Button("Ken Burns…") { store.showKenBurns(span: span.spanID) }
                        .controlSize(.small)
                        .help("Show the span's start and end framings on the program monitor (it opens when the "
                            + "span is selected; this brings it back after it was closed)")
                        .accessibilityIdentifier("KenBurns")
                }
                Button("Remove") { inspector.removeSpan() }
                    .controlSize(.small)
                    .help("Remove the span (⌫)")
                    .accessibilityIdentifier("RemoveSpan")
            }
            if let clip {
                Text("On “\(clip.name)”, lane \(span.lane)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            rangeRows
            HStack(spacing: 4) {
                Text("Interpolation").foregroundStyle(.secondary)
                Spacer()
                Picker("Interpolation", selection: Binding(get: { span.interpolation },
                                                           set: { inspector.setSpanInterpolation($0) })) {
                    ForEach(VEKeyframeInterpolation.choices, id: \.rawValue) { choice in
                        Text(choice.title).tag(choice)
                    }
                    if span.interpolation == .custom {
                        Text(VEKeyframeInterpolation.custom.title).tag(VEKeyframeInterpolation.custom)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(span.interpolation.explanation)
                .accessibilityIdentifier("SpanInterpolation")
            }
            .font(.caption)
            HStack(spacing: 4) {
                Text("Lane").foregroundStyle(.secondary)
                Spacer()
                Picker("Lane", selection: Binding(get: { span.lane }, set: { inspector.moveSpan(toLane: $0) })) {
                    ForEach(1 ... TimelineViewModel.maxEffectLanes, id: \.self) { lane in
                        Text("Lane \(lane)").tag(lane)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("SpanLane")
            }
            .font(.caption)
            Divider()
            valueRows
            HStack(spacing: 6) {
                Button("Match Previous Clip's End") { inspector.matchSpan(.start) }
                    .disabled(!inspector.canMatchSpan(.start))
                    .help("Set the start so the clip's first frame shows what the previous clip's last frame shows")
                    .accessibilityIdentifier("MatchSpanPrevious")
                Button("Match Next Clip's Start") { inspector.matchSpan(.end) }
                    .disabled(!inspector.canMatchSpan(.end))
                    .help("Set the end so the clip's last frame shows what the next clip's first frame shows")
                    .accessibilityIdentifier("MatchSpanNext")
            }
            .controlSize(.small)
            Text(SpanInspector.holdNote(span.kind))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
    }

    static func systemImage(_ kind: VESpanKind) -> String {
        switch kind {
        case .motion: return "arrow.up.left.and.arrow.down.right"
        case .opacity: return "circle.lefthalf.filled"
        case .gain: return "speaker.wave.2"
        default: return "square.on.square.dashed"
        }
    }

    /// The hold-after rule for the span's kind.
    static func holdNote(_ kind: VESpanKind) -> String {
        let what = kind == .gain ? "level" : kind == .opacity ? "opacity" : "framing"
        return "Before its start the span changes nothing; after its end its end \(what) holds until the clip ends. "
            + "A later span applies on top of it. Values are what the picture or sound shows at each end."
    }

    private var rangeRows: some View {
        HStack(spacing: 6) {
            ForEach(InspectorModel.SpanRangeField.allCases, id: \.self) { field in
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.label).foregroundStyle(.secondary)
                    NumericField(text: inspector.spanRangeText(field, of: span), placeholder: "",
                                 commit: { inspector.commitSpanRange(field, $0) },
                                 nudge: { inspector.nudgeSpanRange(field, steps: $0) },
                                 accessibilityIdentifier: "SpanRange.\(field.rawValue)")
                        .frame(height: 20)
                }
            }
        }
        .font(.caption)
        .help("The span's first instant and its end (where the end values are reached), as timeline times; "
            + "↑/↓ move by a frame")
    }

    private var valueRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Spacer()
                Text("Start").frame(width: 84, alignment: .trailing)
                Text("End").frame(width: 84, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ForEach(SpanParameter.parameters(for: span.kind)) { parameter in
                HStack(spacing: 4) {
                    Text(parameter.label).foregroundStyle(.secondary)
                    Spacer()
                    ForEach([false, true], id: \.self) { atEnd in
                        NumericField(text: inspector.spanText(parameter, atEnd: atEnd, of: span), placeholder: "",
                                     commit: { inspector.commitSpanValue(parameter, atEnd: atEnd, $0) },
                                     nudge: { inspector.nudgeSpanValue(parameter, atEnd: atEnd, steps: $0) },
                                     accessibilityIdentifier: "SpanValue.\(parameter.rawValue).\(atEnd ? "end" : "start")")
                            .frame(width: 84, height: 20)
                    }
                }
                .font(.caption)
            }
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
