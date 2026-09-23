import CoreMedia
import SwiftUI
import FramewrightEngine

/// The Ken Burns helper over the program monitor (see `KenBurnsModel`): the whole picture of the
/// clip, unanimated, with the start rectangle (green) and the end rectangle (red), an arrow showing
/// the direction of travel (as in FCP), and a bar with the move's range (Whole clip, From playhead,
/// From clip start, a Duration field and the range as timecodes), the smoothing, Swap, Cancel and
/// Apply. Drag a rectangle to pan, drag a corner to zoom (the aspect ratio stays the frame's). The
/// picture is the clip's unanimated frame at the playhead (its first or last frame while the
/// playhead is outside it) and follows every playhead change, loaded through the thumbnail cache by
/// `KenBurnsPictureLoader` (one fetch at a time, the latest time next), never from the program view.
///
/// Everything drawn comes from observed objects (the model, the playhead, the picture loader), so a
/// change of any of them redraws the overlay.
struct KenBurnsOverlay: View {
    let store: ProjectStore
    @ObservedObject var model: KenBurnsModel
    @ObservedObject var playhead: PlayheadModel
    @ObservedObject var picture: KenBurnsPictureLoader
    let thumbnails: ThumbnailCache
    /// The rectangle as it was when the current drag started.
    @State private var dragOrigin: CGRect?
    @FocusState private var durationFocused: Bool

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
        .onReceive(thumbnails.$version) { _ in picture.update() }
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

    /// The move's range: which part of the clip, its duration and where it starts and ends.
    private var rangeControls: some View {
        HStack(spacing: 8) {
            Picker("Move", selection: $model.range) {
                ForEach(KenBurnsModel.MoveRange.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .fixedSize()
            .help("The part of the clip the move covers; before and after it the framing holds")
            .accessibilityIdentifier("KenBurnsRange")
            Text("Duration")
                .foregroundStyle(model.isDurationEditable ? .primary : .secondary)
            TextField("Duration", text: $model.durationText)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .disabled(!model.isDurationEditable)
                .focused($durationFocused)
                .onSubmit { model.commitDuration() }
                .onChange(of: durationFocused) { _, focused in
                    if !focused { model.commitDuration() }
                }
                .help("How long the move lasts: frames (45f), seconds (2.5s) or timecode")
                .accessibilityIdentifier("KenBurnsDuration")
            Text(model.rangeTimecodes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("The frames of the start and end keyframes")
                .accessibilityIdentifier("KenBurnsRangeTimecodes")
            if let note = model.durationNote ?? model.rangeCaption {
                Text(note)
                    .foregroundStyle(model.rangeProblem != nil || model.durationNote != nil ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
                    .accessibilityIdentifier("KenBurnsRangeCaption")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .background(.bar)
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
                .keyboardShortcut(.defaultAction)
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
            KenBurnsOverlay(store: store, model: model, playhead: store.playhead, picture: picture,
                            thumbnails: store.thumbnails)
        }
    }
}
