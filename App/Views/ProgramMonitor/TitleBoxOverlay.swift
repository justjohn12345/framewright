import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI

/// The selected title's box on the program monitor (`TitleBoxModel`): the text block through the clip's Motion at
/// the playhead, with handles at its corners and on its left and right edges, and thin dashed outlines of the other
/// titles at the playhead. Drag the box to move the text, an edge or a corner to change its wrap width about its
/// centre; each drag is one undo step and Escape cancels it. Double-click the box to type its text on the picture
/// (`PictureTitleEditorView`: the caret and selection are drawn over the picture; Escape or a click outside the box ends
/// it); the handles go while typing. A drag snaps the box to the frame's centre lines and the
/// safe-area edges (the line it snapped to is drawn while it lasts); holding Command does not snap. Nothing is drawn
/// while the playhead is outside the clip, and presses then pass through.
struct TitleBoxOverlay: View {
    @ObservedObject var model: TitleBoxModel
    @ObservedObject var playhead: PlayheadModel
    let viewport: KenBurnsViewport
    /// The drag in progress: what it grabbed (nil when the press grabbed nothing). A gesture state, so it is reset
    /// when the drag ends or is cancelled.
    @GestureState private var drag: ActiveDrag?

    struct ActiveDrag: Equatable {
        let target: TitleBoxModel.Target?
    }

    static let handleSize: CGFloat = 7
    static let tint = Color(red: 1.0, green: 0.82, blue: 0.2)
    /// The colour of a guide line a drag snapped to.
    static let snapTint = Color(red: 1.0, green: 0.25, blue: 0.75)
    /// How near a guide line (view points) a dragged box snaps to it.
    static let snapDistance: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.outlines, id: \.clipID) { outline in
                path(viewport.view(outline.box))
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("TitleBox.outline.\(outline.clipID)")
            }
            if model.isVisible {
                snapLinesView
                boxView
                if let editor = model.editor {
                    PictureTitleEditorView(model: model, editor: editor, viewport: viewport)
                } else {
                    dragLayer
                }
            }
        }
        .accessibilityIdentifier("TitleBoxOverlay")
        .onChange(of: playhead.time, initial: true) { _, time in model.setPlayhead(time) }
        .onChange(of: drag == nil) { _, ended in
            if ended { model.gestureAbandoned() }
        }
    }

    private func path(_ box: KenBurnsBox) -> Path {
        Path { path in
            path.addLines(box.corners)
            path.closeSubpath()
        }
    }

    /// The box, its corner handles and its edge handles (at the middle of the left and right edges; none for point
    /// text, whose width follows its text).
    private var boxView: some View {
        let box = viewport.view(model.box)
        let handles = model.isResizable && model.editor == nil
            ? box.corners + [box.point(local: CGPoint(x: -box.size.width / 2, y: 0)),
                             box.point(local: CGPoint(x: box.size.width / 2, y: 0))]
            : []
        return ZStack(alignment: .topLeading) {
            path(box)
                .stroke(Color.black.opacity(0.5), lineWidth: 3)
            path(box)
                .stroke(Self.tint, lineWidth: 1.5)
                .accessibilityIdentifier("TitleBox.box")
            ForEach(Array(handles.enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(Self.tint)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .rotationEffect(.degrees(box.rotationDegrees))
                    .position(point)
            }
        }
        .allowsHitTesting(false)
    }

    /// The guide lines the drag snapped to, across the frame.
    private var snapLinesView: some View {
        Path { path in
            let frame = viewport.frame
            for line in model.snapLines {
                if line.vertical {
                    let x = viewport.view(CGPoint(x: line.position, y: 0)).x
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                } else {
                    let y = viewport.view(CGPoint(x: 0, y: line.position)).y
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
        }
        .stroke(Self.snapTint, lineWidth: 1)
        .allowsHitTesting(false)
        .accessibilityIdentifier("TitleBox.snapLines")
    }

    /// Presses on the box (`TitleBoxModel.target`) drag it; presses elsewhere grab nothing. A move snaps to the
    /// frame's guide lines unless Command is held.
    private var dragLayer: some View {
        let box = viewport.view(model.box)
        return Color.clear
            .contentShape(TitleBoxHitShape(box: box))
            .gesture(DragGesture(minimumDistance: 0)
                .updating($drag) { value, state, _ in
                    if state == nil {
                        state = ActiveDrag(target: TitleBoxModel.target(at: value.startLocation, box: box,
                                                                        resizable: model.isResizable))
                    }
                    guard let target = state?.target else { return }
                    model.applyDrag(target, translation: viewport.sequence(value.translation),
                                    snapping: !NSEvent.modifierFlags.contains(.command),
                                    snapThreshold: viewport.sequence(CGSize(width: Self.snapDistance, height: 0)).width)
                }
                .onEnded { value in
                    model.endDrag()
                    // The release of a double-click: AppKit's event says how many clicks it ends.
                    if TitleBoxModel.doubleClickStartsTyping(at: value.location, movedBy: value.translation,
                                                            clickCount: NSApp.currentEvent?.clickCount ?? 0, box: box,
                                                            resizable: model.isResizable) {
                        model.beginEditing(.caret(atFramePoint: viewport.sequence(value.location)))
                    }
                })
            // SwiftUI's own double tap as well, so the double-click does not depend on the event AppKit is handling
            // when the drag ends (starting twice is harmless: a second start keeps the session).
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                if TitleBoxModel.doubleClickStartsTyping(at: value.location, movedBy: .zero, clickCount: 2, box: box,
                                                         resizable: model.isResizable) {
                    model.beginEditing(.caret(atFramePoint: viewport.sequence(value.location)))
                }
            })
            .accessibilityIdentifier("TitleBoxDragArea")
    }
}

/// The area a press on the title box grabs: the box widened by the handles' reach, turned with it, so presses
/// elsewhere on the monitor go through to it (and its context menu, its drop target).
struct TitleBoxHitShape: Shape {
    let box: KenBurnsBox

    func path(in rect: CGRect) -> Path {
        let grown = KenBurnsBox(center: box.center,
                                size: CGSize(width: box.size.width + 2 * KenBurnsHit.cornerRadius,
                                             height: box.size.height + 2 * KenBurnsHit.cornerRadius),
                                rotationDegrees: box.rotationDegrees)
        return Path { path in
            path.addLines(grown.corners)
            path.closeSubpath()
        }
    }
}
