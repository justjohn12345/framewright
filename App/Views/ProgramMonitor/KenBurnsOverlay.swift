import CoreMedia
import SwiftUI
import FramewrightEngine

/// The program monitor's picture area and, while a Motion span is selected, its Ken Burns editor
/// (see `KenBurnsModel`). Closed, the picture fills the area (letterboxed by the preview view as
/// usual). Open, the same picture (the same `VEPreviewView`, not a second render path) is drawn
/// fitted inside a margin (`KenBurnsViewport`): the dimmed area around it is the space off the
/// frame, the frame's edge a thin line, so a box larger than the frame or partly off it keeps its
/// corners and body on screen; the editor's boxes and the other clips' outlines are drawn over the
/// whole area and its bar (range, caption, toggles, smoothing, Swap, Close) below it. A selected
/// Opacity or Gain span shows its readout instead. The debug HUD sits at the area's top-left.
/// Observes the store to notice the editor opening, closing and switching.
struct ProgramMonitorLayout<Picture: View>: View {
    @ObservedObject var store: ProjectStore
    var showsHUD = false
    @ViewBuilder var picture: Picture

    var body: some View {
        let editor = store.kenBurns
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let viewport = editor.map { KenBurnsViewport(sequence: $0.sequenceSize, monitor: geometry.size) }
                let frame = viewport?.frame ?? CGRect(origin: .zero, size: geometry.size)
                ZStack(alignment: .topLeading) {
                    editor == nil ? Color.black : KenBurnsOverlay.marginColor
                    // The same picture view open or closed (its place in the tree never changes), only
                    // its frame.
                    picture
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .position(x: frame.midX, y: frame.midY)
                    if let editor, let viewport {
                        KenBurnsOverlay(model: editor, playhead: store.playhead, viewport: viewport)
                    }
                }
                .clipped()
            }
            .overlay(alignment: .topLeading) {
                if let span = store.selectedEffectSpan, editor == nil, span.kind == .opacity || span.kind == .gain {
                    SpanReadout(store: store, span: span)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsHUD {
                    PlaybackHUD(engine: store.engine)
                        .padding(6)
                }
            }
            if let editor {
                KenBurnsControls(store: store, model: editor)
            }
        }
    }
}

/// The Ken Burns editor's drawing over the program picture (`ProgramMonitorLayout` places it over
/// the whole picture area, margin included): the frame's edge, a thin outline of every other clip
/// visible at the playhead labelled with its track, the start box (green) and the end box (red) of
/// the span with their corner handles, an arrow from the start's centre to the end's (as in FCP),
/// and the drag layer. Drag a box to move the clip, a corner to scale it about its centre: every
/// drag writes the span as it moves and is one undo step; Escape mid-drag cancels it. There is no
/// Apply or Cancel.
///
/// Everything drawn comes from observed objects (the model, the playhead), so a change of either
/// redraws the overlay; the model re-reads the span and the outlines on every model change.
struct KenBurnsOverlay: View {
    @ObservedObject var model: KenBurnsModel
    @ObservedObject var playhead: PlayheadModel
    let viewport: KenBurnsViewport
    /// The drag in progress: what it grabbed and the box as it was when it started. A gesture
    /// state, so it is reset when the drag ends or is cancelled (a stale origin never makes the next
    /// drag jump).
    @GestureState private var drag: ActiveDrag?

    struct ActiveDrag: Equatable {
        /// Nil when the press grabbed nothing.
        let target: KenBurnsHit.Target?
        let origin: KenBurnsBox
    }

    static let handleSize: CGFloat = 9
    /// The area around the frame while the editor is open (the space off the frame).
    static let marginColor = Color(white: 0.16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            frameEdge
            ForEach(model.outlines, id: \.clipID) { outline in
                outlineView(outline)
            }
            arrow
            ForEach([KenBurnsModel.Framing.start, .end], id: \.self) { which in
                boxView(which)
            }
            dragLayer
        }
        .accessibilityIdentifier("KenBurnsOverlay")
        // The outlines are read at the program playhead (the frame the monitor shows).
        .onChange(of: playhead.time, initial: true) { _, time in model.setPlayhead(time) }
        // A drag the system abandoned without an end (the view went away, another gesture won) is
        // reverted; a released drag has ended already (and a cancelled one is over).
        .onChange(of: drag == nil) { _, ended in
            if ended { model.gestureAbandoned() }
        }
    }

    /// The frame's edge, a thin line between the picture and the margin.
    private var frameEdge: some View {
        Path { path in path.addRect(viewport.frame) }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("KenBurnsFrameEdge")
    }

    private func path(_ box: KenBurnsBox) -> Path {
        Path { path in
            path.addLines(box.corners)
            path.closeSubpath()
        }
    }

    /// Another clip's box: a thin, dim, dashed outline (unlike the frame's solid edge) and its
    /// track's name at its top-left corner (kept on screen for a box larger than the area).
    private func outlineView(_ outline: KenBurnsModel.Outline) -> some View {
        let box = viewport.view(outline.box)
        let corner = box.corner(.topLeft)
        let label = CGPoint(x: min(max(corner.x, 2), max(2, viewport.monitor.width - 30)),
                            y: min(max(corner.y, 2), max(2, viewport.monitor.height - 14)))
        return ZStack(alignment: .topLeading) {
            path(box)
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            Text(outline.trackName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 3)
                .background(Color.black.opacity(0.45))
                .fixedSize()
                .offset(x: label.x, y: label.y)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("KenBurns.outline.\(outline.trackName)")
    }

    /// The direction the clip travels: from the start box's centre to the end's.
    private var arrow: some View {
        let from = viewport.view(model.start.center)
        let to = viewport.view(model.end.center)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 10
        return Path { path in
            guard hypot(to.x - from.x, to.y - from.y) > head else { return }
            path.move(to: from)
            path.addLine(to: to)
            path.move(to: CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7)))
            path.addLine(to: to)
            path.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7)))
        }
        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }

    private func color(_ which: KenBurnsModel.Framing) -> Color {
        which == .start ? .green : .red
    }

    /// A box as drawn: its border, its label (the start's at the top-left inside, the end's at the
    /// bottom-right, so both show when the boxes coincide; turned with the box) and its corner
    /// handles. Drawing only: presses go to `dragLayer`, which decides what they grab by geometry
    /// (`KenBurnsHit`), so the start stays reachable under the end.
    private func boxView(_ which: KenBurnsModel.Framing) -> some View {
        let box = viewport.view(model.box(which))
        let tint = color(which)
        let name = which == .start ? "start" : "end"
        let label = KenBurnsHit.labelRect(which, of: box)
        let labelCentre = box.point(local: CGPoint(x: label.midX, y: label.midY))
        return ZStack(alignment: .topLeading) {
            path(box)
                .stroke(tint, lineWidth: 2)
                .accessibilityIdentifier("KenBurns.\(name)")
            Text(which == .start ? "Start" : "End")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .background(tint)
                .frame(width: label.width, height: label.height, alignment: which == .start ? .topLeading : .bottomTrailing)
                .rotationEffect(.degrees(box.rotationDegrees))
                .position(labelCentre)
            ForEach(KenBurnsModel.Corner.allCases, id: \.self) { corner in
                let point = box.corner(corner)
                Rectangle()
                    .fill(tint)
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .position(point)
                    .accessibilityIdentifier("KenBurns.\(name).\(String(describing: corner))")
            }
        }
        .allowsHitTesting(false)
    }

    /// Takes every press on the picture area: what it grabs (a box's label, corner, edge or inside)
    /// is decided once when the drag starts; every movement writes the span (the model opens the
    /// drag's undo group on the first one); the release ends the group.
    private var dragLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($drag) { value, state, _ in
                    if state == nil {
                        let target = KenBurnsHit.target(at: value.startLocation, start: viewport.view(model.start),
                                                        end: viewport.view(model.end))
                        state = ActiveDrag(target: target, origin: target.map { model.box($0.framing) } ?? model.end)
                    }
                    guard let active = state, let target = active.target else { return }
                    model.applyDrag(target, origin: active.origin, translation: viewport.sequence(value.translation))
                }
                .onEnded { _ in model.endDrag() })
            .accessibilityIdentifier("KenBurnsDragArea")
    }
}

/// The Ken Burns editor's bar under the program picture: the span's range (Start, End and Duration
/// as timeline times), the hold-after caption or what limited the last edit, the neighbour toggles
/// next to touching clips, the smoothing, Swap and Close.
struct KenBurnsControls: View {
    let store: ProjectStore
    @ObservedObject var model: KenBurnsModel

    var body: some View {
        VStack(spacing: 0) {
            rangeControls
            controls
        }
        .accessibilityIdentifier("KenBurnsControls")
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            rangeRow
            if let text = model.note ?? model.caption {
                Text(text)
                    .foregroundStyle(model.note != nil ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .accessibilityIdentifier("KenBurnsCaption")
            }
            if model.canContinueFromPrevious || model.next != nil {
                neighbourRow
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .background(.bar)
    }

    private var neighbourRow: some View {
        HStack(spacing: 12) {
            if model.canContinueFromPrevious {
                Toggle("Continue from previous clip",
                       isOn: Binding(get: { model.continuesFromPrevious }, set: { model.setContinuesFromPrevious($0) }))
                    .toggleStyle(.checkbox)
                    .help("Start where the previous clip ends: its last frame's position and size (the green box)")
                    .accessibilityIdentifier("KenBurnsContinuePrevious")
            }
            if model.next != nil {
                Toggle("Lead into next clip",
                       isOn: Binding(get: { model.leadsIntoNext }, set: { model.setLeadsIntoNext($0) }))
                    .toggleStyle(.checkbox)
                    .help("End where the next clip starts: its first frame's position and size (the red box)")
                    .accessibilityIdentifier("KenBurnsLeadIntoNext")
            }
            Spacer(minLength: 0)
        }
    }

    private var rangeRow: some View {
        HStack(spacing: 8) {
            Text("Motion span")
                .font(.caption.weight(.semibold))
            field("Start", .start, help: "The move's first instant, as a timeline time (the ruler's)")
            field("End", .end, help: "Where the move reaches its end placement, as a timeline time")
            field("Duration", .duration, help: "How long the move lasts: frames (45f), seconds (2.5s) or timecode")
            Spacer(minLength: 0)
        }
    }

    /// A labelled range field: Return and leaving the field commit it, ↑/↓ move by a frame.
    private func field(_ title: String, _ field: KenBurnsModel.RangeField, help: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            NumericField(text: model.rangeText(field), placeholder: "",
                         commit: { model.commitRange(field, $0) },
                         nudge: { model.nudgeRange(field, steps: $0) },
                         accessibilityIdentifier: "KenBurns\(title)")
                .frame(width: 92, height: 20)
        }
        .help(help)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Label("Start", systemImage: "square").foregroundStyle(.green)
            Label("End", systemImage: "square").foregroundStyle(.red)
            Spacer(minLength: 4)
            Picker("Smoothing", selection: Binding(get: { model.interpolation },
                                                   set: { model.setInterpolation($0) })) {
                ForEach(KenBurnsModel.interpolations, id: \.rawValue) { choice in
                    Text(choice.title).tag(choice)
                }
                if !KenBurnsModel.interpolations.contains(model.interpolation) {
                    Text(model.interpolation.title).tag(model.interpolation)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("How the move starts and ends (Ease In and Out: it accelerates slowly and comes to rest slowly)")
            .accessibilityIdentifier("KenBurnsSmoothing")
            Button {
                model.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Swap the start and end placements")
            .accessibilityIdentifier("KenBurnsSwap")
            Button {
                store.closeKenBurns()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close the Ken Burns editor (Esc); the span stays selected")
            .accessibilityIdentifier("KenBurnsClose")
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// A small readout on the program monitor while an Opacity or Gain span is selected: what its start
/// and end show ("Fade  100 % → 0 %", "Gain  0 dB → −6 dB"), absolute, and its range. The inspector
/// is its editor.
struct SpanReadout: View {
    @ObservedObject var store: ProjectStore
    let span: VEEffectSpan

    var body: some View {
        let parameter = SpanParameter.parameters(for: span.kind).first
        HStack(spacing: 6) {
            Image(systemName: span.kind == .gain ? "speaker.wave.2" : "circle.lefthalf.filled")
            Text(ProjectStore.title(of: span, isAudio: span.kind == .gain))
                .fontWeight(.semibold)
            if let parameter {
                Text(store.inspector.spanText(parameter, atEnd: false, of: span) + " → "
                    + store.inspector.spanText(parameter, atEnd: true, of: span))
                    .monospacedDigit()
                    .accessibilityIdentifier("SpanReadoutValues")
            }
            Text(store.rangeString(start: span.start, end: span.end))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.7)))
        .foregroundStyle(.white)
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityIdentifier("SpanReadout")
    }
}
