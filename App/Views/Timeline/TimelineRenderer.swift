import SwiftUI
import FramewrightEngine

/// Counters of timeline drawing (diagnostics and the redraw-count tests).
@MainActor
enum TimelineDiagnostics {
    /// Track-area canvas draws.
    static var canvasDraws = 0
    /// Playhead overlay body evaluations.
    static var playheadUpdates = 0
}

/// Draws the track area of the timeline into a SwiftUI `GraphicsContext`: rows, clips with
/// thumbnail strips (video) or pre-rendered waveform strips (audio), transitions, the snap line
/// and the marquee. Only what intersects the visible width is drawn. The playhead is not drawn
/// here: it is an overlay of its own, so moving it never redraws the clips.
@MainActor
struct TimelineRenderer {
    let model: TimelineViewModel
    let selection: Set<Int64>
    let selectedTransitionID: Int64?
    let targetTrackIDs: Set<Int64>
    let assets: [VEAssetID: VEAssetInfo]
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache
    let snapTime: Double?
    let marquee: CGRect?
    /// Gain value shown next to the pointer (gain line hovered or dragged).
    var gainTooltip: TimelineGestureController.GainTooltip?
    /// Where a transition dragged from the Transitions panel would land.
    var transitionDrop: TimelineGestureController.TransitionDropTarget?
    /// Formats a transition's duration in sequence frames for its band.
    var formatFrames: (Int64) -> String = { "\($0)f" }

    static let thumbnailMaxDimension = 160
    static let labelHeight: CGFloat = 16

    func draw(in context: inout GraphicsContext, size: CGSize) {
        TimelineDiagnostics.canvasDraws += 1
        drawRows(&context, size: size)
        for clip in model.clips(visibleIn: size.width) {
            drawClip(clip, in: &context, size: size)
        }
        drawTransitions(&context, size: size)
        if let transitionDrop {
            drawDropTarget(transitionDrop, in: &context, size: size)
        }
        if let snapTime {
            let x = model.x(forTime: snapTime)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.yellow), lineWidth: 1)
        }
        if let marquee {
            let rect = marquee.standardized
            context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.15)))
            context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1)
        }
        if let gainTooltip {
            drawTooltip(gainTooltip.text, at: gainTooltip.point, in: &context, size: size)
        }
    }

    /// A small label box next to `point`, kept inside the canvas.
    private func drawTooltip(_ text: String, at point: CGPoint, in context: inout GraphicsContext, size: CGSize) {
        let label = context.resolve(Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundColor(.white))
        let textSize = label.measure(in: CGSize(width: 200, height: 40))
        var box = CGRect(x: point.x + 12, y: point.y - textSize.height - 10, width: textSize.width + 10,
                         height: textSize.height + 4)
        if box.maxX > size.width { box.origin.x = point.x - box.width - 12 }
        if box.minY < 0 { box.origin.y = point.y + 10 }
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color.black.opacity(0.8)))
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    private func drawRows(_ context: inout GraphicsContext, size: CGSize) {
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

    private func drawClip(_ clip: TimelineViewModel.Clip, in context: inout GraphicsContext, size: CGSize) {
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
            drawWaveform(clip, in: content, context: &inner, size: size)
            drawFadesAndGain(clip, in: content, context: &inner)
        } else if let asset, asset.hasVideo, !asset.isMissing {
            drawThumbnails(clip, asset: asset, in: content, context: &inner, size: size)
        }
        if layout.track.muted {
            inner.fill(Path(body), with: .color(Color.black.opacity(0.35)))
        }
        var label = clip.name
        if abs(clip.speed - 1) > 1e-6 {
            label += "  " + SpeedFormat.percent(clip.speed)
        }
        if clip.linkedClipID != 0 {
            label = "⛓ " + label
        }
        if isAudio, abs(clip.gainDb) > 1e-9 {
            label += "  " + TimelineGestureController.gainText(clip.gainDb)
        }
        let text = Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.white)
        let labelX = max(body.minX, 0) + 5
        inner.draw(text, at: CGPoint(x: labelX, y: body.minY + 2), anchor: .topLeading)

        context.stroke(shape, with: .color(isSelected ? .white : Color.black.opacity(0.5)), lineWidth: isSelected ? 2 : 1)
        if isAudio {
            drawFadeHandles(clip, in: &context)
        } else if !clip.keyframes.isEmpty {
            drawKeyframeMarkers(clip, in: &context, size: size, selected: isSelected)
        }
    }

    /// Keyframe markers: small diamonds along a video clip's bottom edge, one per frame that shows
    /// a Motion keyframe (click one to move the playhead there).
    private func drawKeyframeMarkers(_ clip: TimelineViewModel.Clip, in context: inout GraphicsContext, size: CGSize,
                                     selected: Bool) {
        let half = TimelineViewModel.keyframeMarkerSize / 2
        for time in clip.keyframes {
            guard let center = model.keyframeMarkerCenter(forClip: clip, time: time),
                  center.x >= -half, center.x <= size.width + half else { continue }
            var diamond = Path()
            diamond.move(to: CGPoint(x: center.x, y: center.y - half))
            diamond.addLine(to: CGPoint(x: center.x + half, y: center.y))
            diamond.addLine(to: CGPoint(x: center.x, y: center.y + half))
            diamond.addLine(to: CGPoint(x: center.x - half, y: center.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(selected ? .yellow : Color.white.opacity(0.9)))
            context.stroke(diamond, with: .color(.black.opacity(0.7)), lineWidth: 1)
        }
    }

    /// The volume envelope over an audio clip's waveform: the gain line, the fade-in rising from
    /// silence at the clip start to the gain line and the fade-out falling back to silence at
    /// its end, with the silenced area above the fades darkened.
    private func drawFadesAndGain(_ clip: TimelineViewModel.Clip, in content: CGRect, context: inout GraphicsContext) {
        guard content.height > 4 else { return }
        let gainY = TimelineViewModel.gainY(clip.gainDb, in: content)
        let startX = model.x(forTime: clip.start)
        let endX = model.x(forTime: clip.end)
        let fadeInX = model.x(forTime: clip.start + clip.fadeIn)
        let fadeOutX = model.x(forTime: clip.end - clip.fadeOut)
        let shade = Color.black.opacity(0.35)
        if clip.fadeIn > 0 {
            var region = Path()
            region.move(to: CGPoint(x: startX, y: content.minY))
            region.addLine(to: CGPoint(x: startX, y: content.maxY))
            region.addLine(to: CGPoint(x: fadeInX, y: gainY))
            region.addLine(to: CGPoint(x: fadeInX, y: content.minY))
            region.closeSubpath()
            context.fill(region, with: .color(shade))
        }
        if clip.fadeOut > 0 {
            var region = Path()
            region.move(to: CGPoint(x: endX, y: content.minY))
            region.addLine(to: CGPoint(x: endX, y: content.maxY))
            region.addLine(to: CGPoint(x: fadeOutX, y: gainY))
            region.addLine(to: CGPoint(x: fadeOutX, y: content.minY))
            region.closeSubpath()
            context.fill(region, with: .color(shade))
        }
        var envelope = Path()
        envelope.move(to: CGPoint(x: startX, y: clip.fadeIn > 0 ? content.maxY : gainY))
        envelope.addLine(to: CGPoint(x: fadeInX, y: gainY))
        envelope.addLine(to: CGPoint(x: fadeOutX, y: gainY))
        envelope.addLine(to: CGPoint(x: endX, y: clip.fadeOut > 0 ? content.maxY : gainY))
        context.stroke(envelope, with: .color(Color.yellow.opacity(0.9)), lineWidth: 1.2)
    }

    /// The fade handles: small squares at the top corners (at each fade's end).
    private func drawFadeHandles(_ clip: TimelineViewModel.Clip, in context: inout GraphicsContext) {
        let size = TimelineViewModel.fadeHandleSize
        for fadeIn in [true, false] {
            guard let center = model.fadeHandleCenter(forClip: clip, fadeIn: fadeIn) else { continue }
            let square = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            context.fill(Path(square), with: .color(.white))
            context.stroke(Path(square), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func drawThumbnails(_ clip: TimelineViewModel.Clip, asset: VEAssetInfo, in rect: CGRect,
                                context: inout GraphicsContext, size: CGSize) {
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

    /// Draws the clip's part of the asset's pre-rendered waveform strips (see WaveformCache).
    private func drawWaveform(_ clip: TimelineViewModel.Clip, in rect: CGRect, context: inout GraphicsContext,
                              size: CGSize) {
        guard rect.height > 4 else { return }
        let x0 = max(rect.minX, 0)
        let x1 = min(rect.maxX, size.width)
        guard x1 > x0 else { return }
        guard waveforms.waveform(asset: clip.assetID) != nil else {
            let midY = rect.midY
            context.stroke(Path { $0.move(to: CGPoint(x: x0, y: midY)); $0.addLine(to: CGPoint(x: x1, y: midY)) },
                           with: .color(Color.white.opacity(0.3)), lineWidth: 1)
            return
        }
        let speed = max(clip.speed, 1e-6)
        let level = WaveformCache.level(forPointsPerSecond: model.pixelsPerSecond / speed)
        let tileSeconds = WaveformCache.tileSeconds(level: level)
        let sourceStart = clip.sourceIn + (model.time(forX: x0) - clip.start) * speed
        let sourceEnd = clip.sourceIn + (model.time(forX: x1) - clip.start) * speed
        let first = max(0, Int((sourceStart / tileSeconds).rounded(.down)))
        let last = max(first, Int((sourceEnd / tileSeconds).rounded(.down)))
        for index in first ... min(last, first + 256) {
            guard let image = waveforms.strip(asset: clip.assetID, level: level, index: index) else { continue }
            let tileStart = Double(index) * tileSeconds
            let left = model.x(forTime: clip.start + (tileStart - clip.sourceIn) / speed)
            let right = model.x(forTime: clip.start + (tileStart + tileSeconds - clip.sourceIn) / speed)
            context.draw(Image(decorative: image, scale: 1),
                         in: CGRect(x: left, y: rect.minY, width: max(0.5, right - left), height: rect.height))
        }
    }

    /// Transitions: a band across the cut at the top of the row with its duration, resize
    /// handles at both edges and a white outline when selected.
    private func drawTransitions(_ context: inout GraphicsContext, size: CGSize) {
        for transition in model.transitions {
            guard let rect = model.rect(forTransition: transition), rect.maxX >= 0, rect.minX <= size.width else { continue }
            let band = rect.insetBy(dx: 0, dy: 1)
            let shape = Path(roundedRect: band, cornerRadius: 3)
            context.fill(shape, with: .color(Color.purple.opacity(0.9)))
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: band.minX, y: band.maxY))
            diagonal.addLine(to: CGPoint(x: band.maxX, y: band.minY))
            context.stroke(diagonal, with: .color(.white.opacity(0.35)), lineWidth: 1)
            let cutX = model.x(forTime: transition.cut(in: model))
            context.stroke(Path { $0.move(to: CGPoint(x: cutX, y: band.minY)); $0.addLine(to: CGPoint(x: cutX, y: band.maxY)) },
                           with: .color(.white.opacity(0.6)), lineWidth: 1)
            let frames = Int64(((transition.end - transition.start) / max(model.frameSeconds, 1e-9)).rounded())
            let label = context.resolve(Text(formatFrames(frames)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundColor(.white))
            let labelSize = label.measure(in: CGSize(width: 200, height: band.height))
            if labelSize.width + 12 < band.width {
                context.draw(label, at: CGPoint(x: band.midX, y: band.midY), anchor: .center)
            }
            let isSelected = transition.id == selectedTransitionID
            let handleWidth: CGFloat = 3
            if band.width > 12 {
                for x in [band.minX + 1, band.maxX - 1 - handleWidth] {
                    let handle = CGRect(x: x, y: band.minY + 2, width: handleWidth, height: band.height - 4)
                    context.fill(Path(roundedRect: handle, cornerRadius: 1), with: .color(.white.opacity(isSelected ? 0.95 : 0.6)))
                }
            }
            context.stroke(shape, with: .color(isSelected ? .white : .black.opacity(0.4)), lineWidth: isSelected ? 2 : 1)
        }
    }

    /// Drop feedback for a transition dragged from the panel: the cut is highlighted with the
    /// band the transition would get (green) or in red when it cannot take one, with the reason.
    private func drawDropTarget(_ target: TimelineGestureController.TransitionDropTarget,
                                in context: inout GraphicsContext, size: CGSize) {
        guard let layout = model.layout(forTrack: target.trackID) else { return }
        let rowTop = layout.y - model.scrollY
        let color: Color = target.allowed ? .green : .red
        let cutX = model.x(forTime: target.cut)
        context.stroke(Path { $0.move(to: CGPoint(x: cutX, y: rowTop)); $0.addLine(to: CGPoint(x: cutX, y: rowTop + layout.height)) },
                       with: .color(color), lineWidth: 2)
        if target.allowed {
            let x0 = model.x(forTime: target.start)
            let x1 = model.x(forTime: target.end)
            let band = CGRect(x: x0, y: rowTop + 1, width: max(4, x1 - x0), height: TimelineViewModel.transitionStripHeight - 2)
            context.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(color.opacity(0.45)))
            context.stroke(Path(roundedRect: band, cornerRadius: 3), with: .color(color), lineWidth: 1.5)
        }
        let text = target.message.isEmpty ? "\(target.kind.title) · \(formatFrames(target.frames))" : target.message
        let label = context.resolve(Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(.white))
        let textSize = label.measure(in: CGSize(width: 360, height: 60))
        var box = CGRect(x: cutX + 8, y: rowTop + TimelineViewModel.transitionStripHeight + 2,
                         width: textSize.width + 10, height: textSize.height + 4)
        if box.maxX > size.width { box.origin.x = max(0, cutX - box.width - 8) }
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color((target.allowed ? Color.black : Color.red).opacity(0.8)))
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}

/// Speed display: "50%", "33.33%", and exact fractions ("1/3") for values a short decimal
/// cannot show.
enum SpeedFormat {
    static func percent(_ speed: Double) -> String {
        let percent = speed * 100
        if abs(percent - percent.rounded()) < 1e-9 {
            return String(format: "%.0f%%", percent)
        }
        return String(format: "%.2f%%", percent)
    }

    /// The exact speed multiplier: "2", "0.5", "1/3".
    static func multiplier(numerator: Int64, denominator: Int64) -> String {
        guard denominator > 0 else { return "?" }
        if denominator == 1 { return "\(numerator)" }
        // A denominator dividing 1000 has an exact decimal of at most three places.
        if 1000 % denominator == 0 {
            let value = Double(numerator) / Double(denominator)
            var text = String(format: "%.3f", value)
            while text.hasSuffix("0") { text.removeLast() }
            return text
        }
        return "\(numerator)/\(denominator)"
    }

    /// Parses "0.5", "2", "1/3" (a multiplier) into numerator/denominator, or a decimal to be
    /// approximated by the engine. Nil when not a positive number.
    enum Parsed: Equatable {
        case fraction(Int64, Int64)
        case decimal(Double)
    }

    static func parseMultiplier(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let n = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
                  let d = Int64(parts[1].trimmingCharacters(in: .whitespaces)), n > 0, d > 0 else { return nil }
            return .fraction(n, d)
        }
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return .decimal(value)
    }
}
