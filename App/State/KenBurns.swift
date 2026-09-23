import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// The Ken Burns helper (Final Cut Pro's "Ken Burns" crop mode): a start rectangle (green) and an
/// end rectangle (red) drawn over the whole picture on the program monitor. Each rectangle is the
/// part of the picture that fills the frame at that end of the clip; the move between them becomes
/// position and scale keyframes on the clip's first and last frames
/// (`VEEngine.applyKenBurns(clip:start:end:interpolation:)`), smoothed with Ease In and Out by
/// default as in FCP (Linear, Ease Out and Ease In can be chosen). Swap exchanges the two
/// framings, like FCP's swap button.
///
/// Geometry, in sequence pixels (origin at the frame's top-left corner, +y down): the picture is
/// shown as the compositor fits it at scale 1 and no offset (`pictureBounds`). A rectangle keeps
/// the sequence's aspect ratio (FCP locks it too), stays inside the picture (so the frame never
/// shows past the picture's edge) and is at least a tenth of the frame wide (a 1000 % zoom). The
/// clip's rotation is kept: a rectangle frames the unrotated picture and the frame shows it turned
/// by the clip's rotation at that end.
@MainActor
final class KenBurnsModel: ObservableObject {
    enum Framing: CaseIterable {
        case start
        case end
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The interpolations the helper offers (FCP's smoothing choices).
    static let interpolations: [VEKeyframeInterpolation] = [.easeInOut, .easeOut, .easeIn, .linear]
    /// The smallest rectangle, as a fraction of the frame's width (a 1000 % zoom).
    static let minimumWidthFraction = 0.1
    /// The default end framing, as a fraction of the largest one (a gentle push in).
    static let defaultEndFraction = 0.8

    let clipID: VEClipID
    let assetID: VEAssetID
    let sequenceSize: CGSize
    /// The picture as the compositor fits it into the frame at scale 1, no offset.
    let pictureBounds: CGRect
    /// The clip's rotation at its first and last frames (kept by the move).
    let startRotation: Double
    let endRotation: Double
    /// Source seconds of the picture to show under the rectangles.
    let pictureSeconds: Double

    @Published var start: CGRect
    @Published var end: CGRect
    @Published var interpolation: VEKeyframeInterpolation = .easeInOut

    /// Nil when the clip cannot take a Ken Burns move (not a single video clip with a picture, or
    /// one frame long); `reason` says why.
    init?(clip: VEClipInfo, asset: VEAssetInfo, sequence: VESequenceInfo, playhead: CMTime,
          reason: inout String) {
        guard clip.trackKind == .video, asset.hasVideo, asset.width > 0, asset.height > 0 else {
            reason = "Ken Burns works on a clip with a picture."
            return nil
        }
        let frame = sequence.frameDuration
        let lastFrame = CMTimeSubtract(clip.timelineEnd, frame)
        guard sequence.width > 0, sequence.height > 0, frame.isNumeric, lastFrame > clip.timelineStart else {
            reason = "The clip is one frame long: a Ken Burns move needs at least two frames."
            return nil
        }
        clipID = clip.clipID
        assetID = asset.assetID
        sequenceSize = CGSize(width: sequence.width, height: sequence.height)
        pictureBounds = Self.fittedPicture(width: Double(asset.width), height: Double(asset.height),
                                           in: sequenceSize)
        let first = clip.motion(at: clip.timelineStart)
        let last = clip.motion(at: lastFrame)
        startRotation = first.rotationDegrees
        endRotation = last.rotationDegrees
        let inside = clip.timelineStart <= playhead && playhead < clip.timelineEnd
        if clip.isStill {
            pictureSeconds = 0
        } else {
            let offset = inside ? CMTimeSubtract(playhead, clip.timelineStart) : .zero
            pictureSeconds = clip.sourceIn.secondsOrZero + offset.secondsOrZero * clip.speed
        }
        let largest = Self.largestRect(in: pictureBounds, aspect: sequenceSize.width / sequenceSize.height)
        let placed = clip.isAnimated(.positionX) || clip.isAnimated(.positionY) || clip.isAnimated(.scale)
            || first.scale != 1 || first.x != 0 || first.y != 0
        if placed {
            start = largest
            end = largest
            start = constrained(Self.rect(for: VEMotionFraming(x: first.x, y: first.y, scale: first.scale),
                                          sequence: sequenceSize, rotationDegrees: startRotation))
            end = constrained(Self.rect(for: VEMotionFraming(x: last.x, y: last.y, scale: last.scale),
                                        sequence: sequenceSize, rotationDegrees: endRotation))
        } else {
            start = largest
            end = Self.scaled(largest, by: Self.defaultEndFraction)
        }
    }

    // MARK: Geometry

    /// The picture fitted into the frame (centred, aspect kept), as the compositor draws it.
    static func fittedPicture(width: Double, height: Double, in sequence: CGSize) -> CGRect {
        let fit = min(Double(sequence.width) / width, Double(sequence.height) / height)
        let size = CGSize(width: width * fit, height: height * fit)
        return CGRect(x: (sequence.width - size.width) / 2, y: (sequence.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The largest rectangle of `aspect` (width / height) inside `bounds`, centred.
    static func largestRect(in bounds: CGRect, aspect: CGFloat) -> CGRect {
        let width = min(bounds.width, bounds.height * aspect)
        let size = CGSize(width: width, height: width / aspect)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
                      height: size.height)
    }

    static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let size = CGSize(width: rect.width * factor, height: rect.height * factor)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                      height: size.height)
    }

    /// The position and scale that make `rect` (sequence pixels of the unanimated picture) fill the
    /// frame, the picture turned by `rotationDegrees` (clockwise, about its centre as the
    /// compositor does): scale = frame width / rect width, and the rectangle's centre, scaled and
    /// turned, moves to the frame's centre.
    static func framing(for rect: CGRect, sequence: CGSize, rotationDegrees: Double) -> VEMotionFraming {
        let scale = Double(sequence.width / rect.width)
        let cx = Double(rect.midX - sequence.width / 2)
        let cy = Double(rect.midY - sequence.height / 2)
        let theta = rotationDegrees * .pi / 180
        let vx = cos(theta) * cx - sin(theta) * cy
        let vy = sin(theta) * cx + cos(theta) * cy
        return VEMotionFraming(x: -scale * vx, y: -scale * vy, scale: scale)
    }

    /// The inverse of `framing(for:sequence:rotationDegrees:)`.
    static func rect(for framing: VEMotionFraming, sequence: CGSize, rotationDegrees: Double) -> CGRect {
        let scale = max(framing.scale, 1e-6)
        let width = Double(sequence.width) / scale
        let height = Double(sequence.height) / scale
        let vx = -framing.x / scale
        let vy = -framing.y / scale
        let theta = rotationDegrees * .pi / 180
        let cx = cos(theta) * vx + sin(theta) * vy
        let cy = -sin(theta) * vx + cos(theta) * vy
        return CGRect(x: Double(sequence.width) / 2 + cx - width / 2, y: Double(sequence.height) / 2 + cy - height / 2,
                      width: width, height: height)
    }

    private var aspect: CGFloat { sequenceSize.width / sequenceSize.height }
    private var maximumWidth: CGFloat { min(pictureBounds.width, pictureBounds.height * aspect) }
    private var minimumWidth: CGFloat { min(maximumWidth, sequenceSize.width * Self.minimumWidthFraction) }

    /// `rect` with the frame's aspect ratio, within the size limits, moved inside the picture.
    func constrained(_ rect: CGRect) -> CGRect {
        let width = min(maximumWidth, max(minimumWidth, rect.width))
        let size = CGSize(width: width, height: width / aspect)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        origin.x = min(max(origin.x, pictureBounds.minX), pictureBounds.maxX - size.width)
        origin.y = min(max(origin.y, pictureBounds.minY), pictureBounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    func rect(_ which: Framing) -> CGRect {
        which == .start ? start : end
    }

    private func set(_ which: Framing, _ rect: CGRect) {
        if which == .start { start = rect } else { end = rect }
    }

    /// Moves a rectangle from `original` by `delta` (sequence pixels), kept inside the picture.
    func move(_ which: Framing, from original: CGRect, by delta: CGSize) {
        set(which, constrained(original.offsetBy(dx: delta.width, dy: delta.height)))
    }

    /// Resizes a rectangle from `original` by dragging `corner` to `point` (sequence pixels): the
    /// opposite corner stays, the aspect ratio stays the frame's, and the rectangle stays inside the
    /// picture and within the size limits.
    func resize(_ which: Framing, from original: CGRect, corner: Corner, to point: CGPoint) {
        let anchor: CGPoint
        let growsRight: Bool
        let growsDown: Bool
        switch corner {
        case .topLeft:
            anchor = CGPoint(x: original.maxX, y: original.maxY)
            growsRight = false
            growsDown = false
        case .topRight:
            anchor = CGPoint(x: original.minX, y: original.maxY)
            growsRight = true
            growsDown = false
        case .bottomLeft:
            anchor = CGPoint(x: original.maxX, y: original.minY)
            growsRight = false
            growsDown = true
        case .bottomRight:
            anchor = CGPoint(x: original.minX, y: original.minY)
            growsRight = true
            growsDown = true
        }
        let wanted = max(abs(point.x - anchor.x), abs(point.y - anchor.y) * aspect)
        let roomX = growsRight ? pictureBounds.maxX - anchor.x : anchor.x - pictureBounds.minX
        let roomY = growsDown ? pictureBounds.maxY - anchor.y : anchor.y - pictureBounds.minY
        let width = max(min(minimumWidth, roomX, roomY * aspect), min(wanted, maximumWidth, roomX, roomY * aspect))
        let height = width / aspect
        let rect = CGRect(x: growsRight ? anchor.x : anchor.x - width, y: growsDown ? anchor.y : anchor.y - height,
                          width: width, height: height)
        set(which, constrained(rect))
    }

    /// Exchanges the start and end framings (FCP's swap button).
    func swap() {
        (start, end) = (end, start)
    }

    /// The keyframe values the two rectangles give.
    var startFraming: VEMotionFraming {
        Self.framing(for: start, sequence: sequenceSize, rotationDegrees: startRotation)
    }

    var endFraming: VEMotionFraming {
        Self.framing(for: end, sequence: sequenceSize, rotationDegrees: endRotation)
    }
}
