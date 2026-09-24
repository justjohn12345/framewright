import CoreMedia
import SwiftUI
import FramewrightEngine

/// The Ken Burns editor over the program monitor while a Motion span is selected (see
/// `KenBurnsModel`): the whole picture of the clip, unanimated, with the start rectangle (green) and
/// the end rectangle (red) of the span, an arrow showing the direction of travel (as in FCP), and a
/// bar with the span's range (Start, End and Duration as timeline times), the hold-after caption or
/// what limited the last edit, the neighbour toggles, the smoothing, Swap and Close. Drag a rectangle
/// to pan, drag a corner to zoom (the aspect ratio stays the frame's): every drag writes the span as
/// it moves and is one undo step; Escape mid-drag cancels it. There is no Apply or Cancel. The
/// picture is the clip's unanimated frame at the playhead, clamped to the span's range, loaded by
/// `KenBurnsPictureLoader` (its own small cache), never from the program view or the shared
/// thumbnail cache, so pictures landing redraw this overlay alone.
///
/// Everything drawn comes from observed objects (the model, the playhead, the picture loader), so a
/// change of any of them redraws the overlay; the model re-reads the span on every model change.
struct KenBurnsOverlay: View {
    let store: ProjectStore
    @ObservedObject var model: KenBurnsModel
    @ObservedObject var playhead: PlayheadModel
    @ObservedObject var picture: KenBurnsPictureLoader
    /// The drag in progress: what it grabbed and the rectangle as it was when it started. A gesture
    /// state, so it is reset when the drag ends or is cancelled (a stale origin never makes the next
    /// drag jump).
    @GestureState private var drag: ActiveDrag?

    struct ActiveDrag: Equatable {
        /// Nil when the press grabbed nothing.
        let target: KenBurnsHit.Target?
        let origin: CGRect
    }

    static let handleSize: CGFloat = 9

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let mapping = Mapping(sequence: model.sequenceSize, view: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    picture(mapping)
                    shade(mapping)
                    arrow(mapping)
                    ForEach([KenBurnsModel.Framing.start, .end], id: \.self) { which in
                        framingView(which, mapping: mapping)
                    }
                    dragLayer(mapping)
                }
                .clipped()
            }
            rangeControls
            controls
        }
        .background(Color.black)
        .accessibilityIdentifier("KenBurnsOverlay")
        // The picture follows the playhead (within the span's range).
        .onChange(of: playhead.time, initial: true) { _, time in model.setPlayhead(time) }
        .onChange(of: model.pictureSeconds, initial: true) { _, seconds in picture.want(seconds: seconds) }
        // A drag the system abandoned without an end (the view went away, another gesture won) is
        // reverted; a released drag has ended already.
        .onChange(of: drag == nil) { _, ended in
            if ended, model.isDragging { model.cancelDrag() }
        }
    }

    /// Sequence pixels to view points: the frame letterboxed into the view.
    struct Mapping {
        let scale: CGFloat
        let origin: CGPoint

        init(sequence: CGSize, view: CGSize) {
            scale = max(1e-6, min(view.width / max(sequence.width, 1), view.height / max(sequence.height, 1)))
            origin = CGPoint(x: (view.width - sequence.width * scale) / 2, y: (view.height - sequence.height * scale) / 2)
        }

        func view(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale, width: rect.width * scale,
                   height: rect.height * scale)
        }

        func view(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
        }

        func sequence(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
        }

        func sequence(_ size: CGSize) -> CGSize {
            CGSize(width: size.width / scale, height: size.height / scale)
        }
    }

    @ViewBuilder
    private func picture(_ mapping: Mapping) -> some View {
        let bounds = mapping.view(model.pictureBounds)
        if let image = picture.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.35))
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)
        }
    }

    /// Darkens the picture outside both rectangles.
    private func shade(_ mapping: Mapping) -> some View {
        Path { path in
            path.addRect(mapping.view(model.pictureBounds))
            path.addRect(mapping.view(model.start))
            path.addRect(mapping.view(model.end))
        }
        .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// The direction the picture travels: from the start rectangle's centre to the end's.
    private func arrow(_ mapping: Mapping) -> some View {
        let from = mapping.view(CGPoint(x: model.start.midX, y: model.start.midY))
        let to = mapping.view(CGPoint(x: model.end.midX, y: model.end.midY))
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

    /// A rectangle as drawn: its border, its label (the start's at the top-left inside, the end's at
    /// the bottom-right, so both show when the rectangles coincide) and its corner handles. Drawing
    /// only: presses go to `dragLayer`, which decides what they grab by geometry (`KenBurnsHit`), so
    /// the start stays reachable under the end.
    private func framingView(_ which: KenBurnsModel.Framing, mapping: Mapping) -> some View {
        let rect = mapping.view(model.rect(which))
        let tint = color(which)
        let name = which == .start ? "start" : "end"
        let label = KenBurnsHit.labelRect(which, of: rect)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(tint, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .accessibilityIdentifier("KenBurns.\(name)")
            Text(which == .start ? "Start" : "End")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .background(tint)
                .frame(width: label.width, height: label.height, alignment: which == .start ? .topLeading : .bottomTrailing)
                .offset(x: label.minX, y: label.minY)
            ForEach(KenBurnsModel.Corner.allCases, id: \.self) { corner in
                let point = KenBurnsHit.cornerPoint(corner, of: rect)
                Rectangle()
                    .fill(tint)
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
                    .accessibilityIdentifier("KenBurns.\(name).\(String(describing: corner))")
            }
        }
        .allowsHitTesting(false)
    }

    /// Takes every press on the picture area: what it grabs (a rectangle's label, corner, edge or
    /// inside) is decided once when the drag starts; every movement writes the span (the model opens
    /// the drag's undo group on the first one); the release ends the group.
    private func dragLayer(_ mapping: Mapping) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($drag) { value, state, _ in
                    if state == nil {
                        let target = KenBurnsHit.target(at: value.startLocation, start: mapping.view(model.start),
                                                        end: mapping.view(model.end))
                        state = ActiveDrag(target: target, origin: target.map { model.rect($0.framing) } ?? .zero)
                    }
                    guard let active = state, let target = active.target else { return }
                    model.applyDrag(target, origin: active.origin, translation: mapping.sequence(value.translation),
                                    location: mapping.sequence(value.location))
                }
                .onEnded { _ in model.endDrag() })
            .accessibilityIdentifier("KenBurnsDragArea")
    }

    /// The span's range, what the last edit hit (or the hold-after caption) and, next to touching
    /// clips, whether the rectangles follow them.
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
                    .help("Start on the framing the previous clip ends with (the green rectangle)")
                    .accessibilityIdentifier("KenBurnsContinuePrevious")
            }
            if model.next != nil {
                Toggle("Lead into next clip",
                       isOn: Binding(get: { model.leadsIntoNext }, set: { model.setLeadsIntoNext($0) }))
                    .toggleStyle(.checkbox)
                    .help("End on the framing the next clip starts with (the red rectangle)")
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
            field("End", .end, help: "Where the move reaches its end framing, as a timeline time")
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
            .help("Swap the start and end framings")
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

/// Shows the Ken Burns editor over the program monitor while a Motion span is selected (and it was
/// not closed), or the readout of a selected Opacity or Gain span. Observes the store to notice the
/// selection and the editor changing.
struct KenBurnsOverlayHost: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        if let model = store.kenBurns, let picture = model.picture {
            KenBurnsOverlay(store: store, model: model, playhead: store.playhead, picture: picture)
        } else if let span = store.selectedEffectSpan, span.kind == .opacity || span.kind == .gain {
            VStack {
                HStack {
                    SpanReadout(store: store, span: span)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
