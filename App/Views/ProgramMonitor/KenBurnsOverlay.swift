import CoreMedia
import SwiftUI
import FramewrightEngine

/// The Ken Burns helper over the program monitor (see `KenBurnsModel`): the whole picture of the
/// clip, unanimated, with the start rectangle (green) and the end rectangle (red), an arrow showing
/// the direction of travel (as in FCP), and a bar with the move's range (Whole clip, From playhead,
/// From clip start, Existing move when the clip has one, Custom; Start, End and Duration fields),
/// the smoothing, Swap, Cancel and Apply. Drag a rectangle to pan, drag a corner to
/// zoom (the aspect ratio stays the frame's). The picture is the clip's unanimated frame at the
/// playhead (its first or last frame while the playhead is outside it) and follows every playhead
/// change, loaded by `KenBurnsPictureLoader` (its own small cache, one fetch at a time, each landed
/// picture shown before the latest time is fetched), never from the program view or the shared
/// thumbnail cache, so pictures landing redraw this overlay alone.
///
/// Everything drawn comes from observed objects (the model, the playhead, the picture loader), so a
/// change of any of them redraws the overlay.
struct KenBurnsOverlay: View {
    let store: ProjectStore
    @ObservedObject var model: KenBurnsModel
    @ObservedObject var playhead: PlayheadModel
    @ObservedObject var picture: KenBurnsPictureLoader
    /// The rectangle as it was when the current drag started.
    @State private var dragOrigin: CGRect?
    @FocusState private var focusedField: RangeField?

    /// The bar's text fields.
    enum RangeField: Hashable {
        case start, end, duration
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
                }
                .clipped()
            }
            rangeControls
            controls
        }
        .background(Color.black)
        .accessibilityIdentifier("KenBurnsOverlay")
        // The picture and a "From playhead" range follow the playhead while the helper is open.
        .onChange(of: playhead.time, initial: true) { _, time in model.setPlayhead(time) }
        .onChange(of: model.pictureSeconds, initial: true) { _, seconds in picture.want(seconds: seconds) }
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

    private func framingView(_ which: KenBurnsModel.Framing, mapping: Mapping) -> some View {
        let rect = mapping.view(model.rect(which))
        let tint = color(which)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(tint, lineWidth: 2)
                .background(Color.white.opacity(0.001)) // hit-testable inside
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .topLeading) {
                    Text(which == .start ? "Start" : "End")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .background(tint)
                }
                .offset(x: rect.minX, y: rect.minY)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = dragOrigin ?? model.rect(which)
                        dragOrigin = origin
                        model.move(which, from: origin, by: mapping.sequence(value.translation))
                    }
                    .onEnded { _ in dragOrigin = nil })
                .accessibilityIdentifier("KenBurns.\(which == .start ? "start" : "end")")
            ForEach(KenBurnsModel.Corner.allCases, id: \.self) { corner in
                let point = cornerPoint(corner, of: rect)
                Rectangle()
                    .fill(tint)
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let origin = dragOrigin ?? model.rect(which)
                            dragOrigin = origin
                            model.resize(which, from: origin, corner: corner, to: mapping.sequence(value.location))
                        }
                        .onEnded { _ in dragOrigin = nil })
            }
        }
    }

    private func cornerPoint(_ corner: KenBurnsModel.Corner, of rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The move's range (which part of the clip, where it starts and ends, its duration), what it
    /// means (or why it was limited) and, next to touching clips, whether the rectangles follow them.
    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            rangeRow
            if model.rangeNote != nil || model.rangeCaption != nil {
                captionRow
            }
            if model.previous != nil || model.next != nil {
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
            if model.previous != nil {
                Toggle("Continue from previous clip", isOn: $model.continuesFromPrevious)
                    .toggleStyle(.checkbox)
                    .help("Start from the framing the previous clip ends with (the green rectangle)")
                    .accessibilityIdentifier("KenBurnsContinuePrevious")
            }
            if model.next != nil {
                Toggle("Lead into next clip", isOn: $model.leadsIntoNext)
                    .toggleStyle(.checkbox)
                    .help("End on the framing the next clip starts with (the red rectangle)")
                    .accessibilityIdentifier("KenBurnsLeadIntoNext")
            }
            if let note = model.neighbourNote {
                Text(note)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
            }
            Spacer(minLength: 0)
        }
    }

    private var rangeRow: some View {
        HStack(spacing: 8) {
            Picker("Move", selection: $model.range) {
                ForEach(model.rangeChoices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .fixedSize()
            .help("The part of the clip the move covers; before and after it the framing holds")
            .accessibilityIdentifier("KenBurnsRange")
            field("Start", text: $model.startText, field: .start, enabled: true,
                  help: "The move's first frame, as a timeline time (the ruler's); typing one makes the range Custom")
            field("End", text: $model.endText, field: .end, enabled: true,
                  help: "The move's last frame, where the end keyframes go, as a timeline time; typing one makes "
                      + "the range Custom")
            field("Duration", text: $model.durationText, field: .duration, enabled: model.isDurationEditable,
                  help: "How long the move lasts: frames (45f), seconds (2.5s) or timecode")
            Spacer(minLength: 0)
        }
        .help(model.rangeTimecodes)
    }

    /// A labelled field of the bar: Return and leaving the field commit it (see `commit(_:)`).
    private func field(_ title: String, text: Binding<String>, field: RangeField, enabled: Bool,
                       help: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(enabled ? .primary : .secondary)
            TextField(title, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 92)
                .disabled(!enabled)
                .focused($focusedField, equals: field)
                .onSubmit { commit(field) }
        }
        .help(help)
        .accessibilityIdentifier("KenBurns\(title)")
        .onChange(of: focusedField) { old, new in
            if old == field, new != field { commit(field) }
        }
    }

    /// Commits a field's text. Return does this without pressing Apply while the text differs from
    /// the committed value (Apply's default-button shortcut is off then: `hasUncommittedText`);
    /// once committed, Return presses Apply.
    private func commit(_ field: RangeField) {
        switch field {
        case .start: model.commitStart()
        case .end: model.commitEnd()
        case .duration: model.commitDuration()
        }
    }

    /// Why a typed value was refused or limited (orange), else what the range means.
    private var captionRow: some View {
        HStack(spacing: 8) {
            if let note = model.rangeNote ?? model.rangeCaption {
                Text(note)
                    .foregroundStyle(model.rangeProblem != nil || model.rangeNote != nil ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
                    .accessibilityIdentifier("KenBurnsRangeCaption")
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Label("Start", systemImage: "square").foregroundStyle(.green)
            Label("End", systemImage: "square").foregroundStyle(.red)
            Spacer(minLength: 4)
            Picker("Smoothing", selection: $model.interpolation) {
                ForEach(KenBurnsModel.interpolations, id: \.rawValue) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("How the move starts and ends (Ease In and Out: it accelerates slowly and comes to rest slowly)")
            Button {
                model.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Swap the start and end framings")
            .accessibilityIdentifier("KenBurnsSwap")
            Button("Cancel") { store.cancelKenBurns() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { store.applyKenBurns() }
                // Return in a field with text still being typed commits the field only.
                .keyboardShortcut(model.hasUncommittedText ? nil : .defaultAction)
                .disabled(model.rangeProblem != nil)
                .accessibilityIdentifier("KenBurnsApply")
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// Shows the Ken Burns helper over the program monitor while one is open. Observes the store only
/// to notice the helper opening and closing.
struct KenBurnsOverlayHost: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        if let model = store.kenBurns, let picture = model.picture {
            KenBurnsOverlay(store: store, model: model, playhead: store.playhead, picture: picture)
        }
    }
}
