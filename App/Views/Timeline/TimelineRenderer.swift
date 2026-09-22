import SwiftUI
import VidEditEngine

/// Draws the track area of the timeline into a SwiftUI `GraphicsContext`: rows, clips with
/// thumbnail strips (video) or waveforms (audio), transitions, the snap line, the playhead and
/// the marquee. Only what intersects the visible width is drawn.
@MainActor
struct TimelineRenderer {
    let model: TimelineViewModel
    let size: CGSize
    let selection: Set<Int64>
    let selectedTransitionID: Int64?
    let targetTrackIDs: Set<Int64>
    let assets: [VEAssetID: VEAssetInfo]
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache
    let snapTime: Double?
    let marquee: CGRect?

    static let thumbnailMaxDimension = 160
    static let labelHeight: CGFloat = 16

    func draw(in context: inout GraphicsContext) {
        drawRows(&context)
        for clip in model.clips(visibleIn: size.width) {
            drawClip(clip, in: &context)
        }
        drawTransitions(&context)
        if let snapTime {
            let x = model.x(forTime: snapTime)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.yellow), lineWidth: 1)
        }
        let playheadX = model.x(forTime: model.playhead)
        context.stroke(Path { $0.move(to: CGPoint(x: playheadX, y: 0)); $0.addLine(to: CGPoint(x: playheadX, y: size.height)) },
                       with: .color(.red), lineWidth: 1.5)
        if let marquee {
            let rect = marquee.standardized
            context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.15)))
            context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1)
        }
    }

    private func drawRows(_ context: inout GraphicsContext) {
        for layout in model.trackLayouts {
            let rect = CGRect(x: 0, y: layout.y - model.scrollY, width: size.width, height: layout.height)
            guard rect.maxY >= 0, rect.minY <= size.height else { continue }
            let base = layout.track.kind == .video ? Color.blue.opacity(0.06) : Color.green.opacity(0.05)
            context.fill(Path(rect), with: .color(base))
            if targetTrackIDs.contains(layout.track.id) {
                context.fill(Path(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height)), with: .color(.accentColor))
            }
            if layout.track.locked {
                context.fill(Path(rect), with: .color(Color.gray.opacity(0.15)))
            }
        }
    }

    private func drawClip(_ clip: TimelineViewModel.Clip, in context: inout GraphicsContext) {
        guard let rect = model.rect(forClip: clip), rect.maxY >= 0, rect.minY <= size.height,
              let layout = model.layout(forTrack: clip.trackID) else { return }
        let isAudio = layout.track.kind == .audio
        let isSelected = selection.contains(clip.id)
        let asset = assets[clip.assetID]
        let body = rect.insetBy(dx: 0.5, dy: 1)
        let shape = Path(roundedRect: body, cornerRadius: 4)
        var fill = isAudio ? Color(red: 0.18, green: 0.42, blue: 0.28) : Color(red: 0.22, green: 0.32, blue: 0.58)
        if asset?.isMissing == true { fill = Color(red: 0.55, green: 0.18, blue: 0.18) }
        context.fill(shape, with: .color(fill.opacity(isSelected ? 1 : 0.85)))

        var inner = context
        inner.clip(to: shape)
        let content = CGRect(x: body.minX, y: body.minY + Self.labelHeight, width: body.width,
                             height: max(0, body.height - Self.labelHeight))
        if isAudio {
            drawWaveform(clip, in: content, context: &inner)
        } else if let asset, asset.hasVideo, !asset.isMissing {
            drawThumbnails(clip, asset: asset, in: content, context: &inner)
        }
        if layout.track.muted {
            inner.fill(Path(body), with: .color(Color.black.opacity(0.35)))
        }
        var label = clip.name
        if abs(clip.speed - 1) > 1e-6 {
            label += String(format: "  %.0f%%", clip.speed * 100)
        }
        if clip.linkedClipID != 0 {
            label = "⛓ " + label
        }
        let text = Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.white)
        let labelX = max(body.minX, 0) + 5
        inner.draw(text, at: CGPoint(x: labelX, y: body.minY + 2), anchor: .topLeading)

        context.stroke(shape, with: .color(isSelected ? .white : Color.black.opacity(0.5)), lineWidth: isSelected ? 2 : 1)
    }

    private func drawThumbnails(_ clip: TimelineViewModel.Clip, asset: VEAssetInfo, in rect: CGRect,
                                context: inout GraphicsContext) {
        guard rect.height > 8, rect.width > 4 else { return }
        let aspect = asset.width > 0 && asset.height > 0 ? CGFloat(asset.width) / CGFloat(asset.height) : 16.0 / 9.0
        let tileWidth = max(8, rect.height * aspect)
        let tileSeconds = Double(tileWidth) / model.pixelsPerSecond
        // Quantize source times to a power-of-two grid near the tile duration so zooming and
        // scrolling reuse cached thumbnails.
        let quantum = pow(2, (log2(max(tileSeconds * clip.speed, 1.0 / 30.0))).rounded())
        let firstTile = max(0, Int(((0 - rect.minX) / tileWidth).rounded(.down)))
        var index = firstTile
        while true {
            let x = rect.minX + CGFloat(index) * tileWidth
            if x > min(rect.maxX, size.width) { break }
            let tileRect = CGRect(x: x, y: rect.minY, width: tileWidth, height: rect.height)
            let timelineTime = clip.start + Double(CGFloat(index) * tileWidth + tileWidth / 2) / model.pixelsPerSecond
            var sourceTime = clip.isStill ? 0 : clip.sourceIn + (timelineTime - clip.start) * clip.speed
            sourceTime = (sourceTime / quantum).rounded(.down) * quantum
            if let image = thumbnails.image(asset: clip.assetID, seconds: sourceTime, maxDimension: Self.thumbnailMaxDimension) {
                context.draw(Image(decorative: image, scale: 1), in: tileRect)
            }
            index += 1
            if index - firstTile > 400 { break }
        }
    }

    private func drawWaveform(_ clip: TimelineViewModel.Clip, in rect: CGRect, context: inout GraphicsContext) {
        guard rect.height > 4 else { return }
        let midY = rect.midY
        guard let waveform = waveforms.waveform(asset: clip.assetID) else {
            context.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: midY)) },
                           with: .color(Color.white.opacity(0.3)), lineWidth: 1)
            return
        }
        let halfHeight = rect.height / 2 - 1
        let step: CGFloat = 2
        var path = Path()
        var x = max(rect.minX, 0)
        let end = min(rect.maxX, size.width)
        while x < end {
            let t0 = clip.sourceIn + (model.time(forX: x) - clip.start) * clip.speed
            let t1 = clip.sourceIn + (model.time(forX: x + step) - clip.start) * clip.speed
            let peak = waveform.peakRange(fromSeconds: t0, toSeconds: t1)
            let top = midY - CGFloat(max(0, peak.maximum)) * halfHeight
            let bottom = midY - CGFloat(min(0, peak.minimum)) * halfHeight
            path.addRect(CGRect(x: x, y: top, width: step - 0.5, height: max(0.5, bottom - top)))
            x += step
        }
        context.fill(path, with: .color(Color(red: 0.55, green: 0.95, blue: 0.65).opacity(0.9)))
    }

    private func drawTransitions(_ context: inout GraphicsContext) {
        for transition in model.transitions {
            guard let rect = model.rect(forTransition: transition), rect.maxX >= 0, rect.minX <= size.width else { continue }
            let shape = Path(roundedRect: rect.insetBy(dx: 0, dy: 1), cornerRadius: 3)
            context.fill(shape, with: .color(Color.purple.opacity(0.85)))
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            diagonal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.stroke(diagonal, with: .color(.white.opacity(0.7)), lineWidth: 1)
            let isSelected = transition.id == selectedTransitionID
            context.stroke(shape, with: .color(isSelected ? .white : .black.opacity(0.4)), lineWidth: isSelected ? 2 : 1)
        }
    }
}
