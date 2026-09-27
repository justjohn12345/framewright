import SwiftUI
import FramewrightEngine

/// Counters of timeline drawing (diagnostics and the redraw-count tests).
@MainActor
enum TimelineDiagnostics {
    /// Track-area canvas draws.
    static var canvasDraws = 0
    /// Playhead overlay body evaluations.
    static var playheadUpdates = 0
    /// Where the ruler and the track area were last laid out (window coordinates; tests).
    static var rulerFrame: CGRect = .zero
    static var trackAreaFrame: CGRect = .zero
}

/// Draws the track area of the timeline into a SwiftUI `GraphicsContext`: rows and their lanes,
/// clips with thumbnail strips (video) or pre-rendered waveform strips (audio), the spans on the
/// lanes (transitions on lane 0 across their cut, effect spans within their clip), the span being
/// created by a range drag, a transition drop's target, the snap line and the marquee. Only what
/// intersects the visible width is drawn. The playhead is not drawn here: it is an overlay of its
/// own, so moving it never redraws the clips.
@MainActor
struct TimelineRenderer {
    let model: TimelineViewModel
    let selection: Set<Int64>
    let selectedSpanID: Int64?
    let targetTrackIDs: Set<Int64>
    let assets: [VEAssetID: VEAssetInfo]
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache
    let snapTime: Double?
    let marquee: CGRect?
    /// Gain value shown next to the pointer (gain line hovered or dragged).
    var gainTooltip: TimelineGestureController.GainTooltip?
    /// Where a transition dragged from the Effects tab would land.
    var transitionDrop: TimelineGestureController.TransitionDropTarget?
    /// Where an effect dragged from the Effects tab would land.
    var effectDrop: TimelineGestureController.EffectDropTarget?
    /// The span a range drag on an empty lane is creating.
    var creation: TimelineGestureController.SpanCreation?
    /// Formats a transition's duration in sequence frames for its band (a function of the sequence's
    /// frame duration and the duration display, which the redraw token covers).
    var formatFrames: (Int64) -> String = { "\($0)f" }

    /// Whether `other` draws the same picture (everything but `formatFrames`, whose inputs change the
    /// canvas's redraw token).
    func drawsLike(_ other: TimelineRenderer) -> Bool {
        model == other.model && selection == other.selection && selectedSpanID == other.selectedSpanID
            && targetTrackIDs == other.targetTrackIDs && assets == other.assets && thumbnails === other.thumbnails
            && waveforms === other.waveforms && snapTime == other.snapTime && marquee == other.marquee
            && gainTooltip == other.gainTooltip && transitionDrop == other.transitionDrop
            && effectDrop == other.effectDrop && creation == other.creation
    }

    static let thumbnailMaxDimension = 160
    static let labelHeight: CGFloat = 16

    func draw(in context: inout GraphicsContext, size: CGSize) {
        TimelineDiagnostics.canvasDraws += 1
        drawRows(&context, size: size)
        for clip in model.clips(visibleIn: size.width) {
            drawClip(clip, in: &context, size: size)
        }
        for span in model.spans(visibleIn: size.width) {
            drawSpan(span, in: &context)
        }
        if let creation {
            drawCreation(creation, in: &context, size: size)
        }
        if let transitionDrop {
            drawDropTarget(transitionDrop, in: &context, size: size)
        }
        if let effectDrop {
            drawEffectDrop(effectDrop, in: &context, size: size)
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
            let whole = CGRect(x: 0, y: layout.y - model.scrollY, width: size.width, height: layout.height)
            guard whole.maxY >= 0, whole.minY <= size.height else { continue }
            let row = CGRect(x: 0, y: whole.minY, width: size.width, height: layout.rowHeight)
            let base = layout.track.kind == .video ? Color.blue.opacity(0.06) : Color.green.opacity(0.05)
            context.fill(Path(row), with: .color(base))
            // The lanes: a darker strip each, a hairline between them.
            for lane in layout.lanes {
                guard let rect = model.laneRect(track: layout.track.id, lane: lane, width: size.width) else { continue }
                context.fill(Path(rect), with: .color(Color.primary.opacity(lane == 0 ? 0.07 : 0.045)))
                context.fill(Path(CGRect(x: 0, y: rect.minY, width: size.width, height: 0.5)),
                             with: .color(Color.primary.opacity(0.12)))
            }
            if targetTrackIDs.contains(layout.track.id) {
                context.fill(Path(CGRect(x: 0, y: row.minY, width: 3, height: row.height)), with: .color(.accentColor))
            }
            if layout.track.locked {
                context.fill(Path(whole), with: .color(Color.gray.opacity(0.15)))
            }
        }
    }

    /// The fill of a span's bar by kind.
    static func color(_ kind: TimelineViewModel.SpanKind) -> Color {
        TimelineItemStyle.baseFill(TimelineItemStyle.Kind(kind)).color
    }

    /// How a clip, span bar or transition bar of `kind` is drawn, selected or not (`TimelineItemStyle`).
    static func style(for kind: TimelineItemStyle.Kind, selected: Bool) -> TimelineItemStyle {
        TimelineItemStyle(kind: kind, selected: selected)
    }

    /// Strokes the item's outline: a selected item's accent border inside its shape (the stroke's path
    /// is the shape inset by half the border's width, so the whole border lies within the item and its
    /// hit area), an unselected item's hairline on its edge.
    private func strokeOutline(of rect: CGRect, cornerRadius: CGFloat, style: TimelineItemStyle,
                               in context: inout GraphicsContext) {
        let inset = style.borderInset
        let path = Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: max(0, cornerRadius - inset))
        context.stroke(path, with: .color(style.borderColor), lineWidth: style.borderWidth)
    }

    /// A span: a rounded bar on its lane with its kind's icon and name (and a transition's length),
    /// a transition's cut marked by a line; selected, a brighter fill and an accent border inside it.
    private func drawSpan(_ span: TimelineViewModel.Span, in context: inout GraphicsContext) {
        guard let rect = model.rect(forSpan: span) else { return }
        let style = Self.style(for: TimelineItemStyle.Kind(span.kind), selected: span.id == selectedSpanID)
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(shape, with: .color(style.fillColor))
        var inner = context
        inner.clip(to: shape)
        if span.kind == .transition {
            let cutX = model.x(forTime: span.cut)
            if cutX > rect.minX + 1, cutX < rect.maxX - 1 {
                inner.stroke(Path { $0.move(to: CGPoint(x: cutX, y: rect.minY)); $0.addLine(to: CGPoint(x: cutX, y: rect.maxY)) },
                             with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
        }
        let visibleMinX = max(rect.minX, 0)
        var x = visibleMinX + 3
        if rect.width >= 16 {
            var icon = inner.resolve(Image(systemName: span.systemImage))
            icon.shading = .color(style.labelColor)
            let side = rect.height - 3
            inner.draw(icon, in: CGRect(x: x, y: rect.midY - side / 2, width: side, height: side))
            x += side + 3
        }
        var title = span.glyph.map { "\($0) " + span.title } ?? span.title
        if span.kind == .transition {
            let frames = Int64(((span.end - span.start) / max(model.frameSeconds, 1e-9)).rounded())
            title += "  " + formatFrames(frames)
        }
        let label = inner.resolve(Text(title).font(.system(size: 9, weight: .semibold)).foregroundColor(style.labelColor))
        let labelSize = label.measure(in: CGSize(width: 400, height: rect.height))
        if x + labelSize.width <= rect.maxX - 2 {
            inner.draw(label, at: CGPoint(x: x, y: rect.midY), anchor: .leading)
        }
        strokeOutline(of: rect, cornerRadius: 3, style: style, in: &context)
    }

    /// The span a range drag on an empty lane creates: its kind's colour, outlined, or red with the
    /// reason when it cannot go there.
    private func drawCreation(_ creation: TimelineGestureController.SpanCreation, in context: inout GraphicsContext,
                              size: CGSize) {
        guard let lane = model.laneRect(track: creation.trackID, lane: creation.lane, width: size.width) else { return }
        let x0 = model.x(forTime: creation.start)
        let x1 = model.x(forTime: creation.end)
        let rect = CGRect(x: x0, y: lane.minY + 1, width: max(2, x1 - x0), height: lane.height - 2)
        let color = creation.problem == nil ? Self.color(creation.kind) : Color.red
        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.45)))
        context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(color), lineWidth: 1.5)
    }

    /// An effect dragged from the Effects tab: the range it would get on its lane (green), or the
    /// lane in red with the reason.
    private func drawEffectDrop(_ target: TimelineGestureController.EffectDropTarget, in context: inout GraphicsContext,
                                size: CGSize) {
        guard let lane = model.laneRect(track: target.trackID, lane: target.lane, width: size.width) else { return }
        let color: Color = target.allowed ? .green : .red
        let x0 = model.x(forTime: target.start)
        let x1 = model.x(forTime: target.end)
        let band = CGRect(x: x0, y: lane.minY + 1, width: max(4, x1 - x0), height: lane.height - 2)
        context.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(color.opacity(0.45)))
        context.stroke(Path(roundedRect: band, cornerRadius: 3), with: .color(color), lineWidth: 1.5)
        guard !target.message.isEmpty else { return }
        drawNote(target.message, at: CGPoint(x: x0, y: lane.maxY + 2), color: target.allowed ? .black : .red,
                 in: &context, size: size)
    }

    /// A small note box below `point` (kept inside the canvas).
    private func drawNote(_ text: String, at point: CGPoint, color: Color, in context: inout GraphicsContext,
                          size: CGSize) {
        let label = context.resolve(Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(.white))
        let textSize = label.measure(in: CGSize(width: 360, height: 60))
        var box = CGRect(x: point.x, y: point.y, width: textSize.width + 10, height: textSize.height + 4)
        if box.maxX > size.width { box.origin.x = max(0, size.width - box.width) }
        if box.maxY > size.height { box.origin.y = max(0, point.y - box.height - 18) }
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(color.opacity(0.8)))
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    private func drawClip(_ clip: TimelineViewModel.Clip, in context: inout GraphicsContext, size: CGSize) {
        guard let rect = model.rect(forClip: clip), rect.maxY >= 0, rect.minY <= size.height,
              let layout = model.layout(forTrack: clip.trackID) else { return }
        let isAudio = layout.track.kind == .audio
        let asset = assets[clip.assetID]
        let kind: TimelineItemStyle.Kind = asset?.isMissing == true ? .missingClip : (isAudio ? .audioClip : .videoClip)
        let style = Self.style(for: kind, selected: selection.contains(clip.id))
        let body = rect.insetBy(dx: 0.5, dy: 1)
        let shape = Path(roundedRect: body, cornerRadius: 4)
        context.fill(shape, with: .color(style.fillColor))

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
        var label = clip.title
        if abs(clip.speed - 1) > 1e-6 {
            label += "  " + SpeedFormat.percent(clip.speed)
        }
        if clip.linkedClipID != 0 {
            label = "⛓ " + label
        }
        if isAudio, abs(clip.gainDb) > 1e-9 {
            label += "  " + TimelineGestureController.gainText(clip.gainDb)
        }
        let text = Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(style.labelColor)
        let labelX = max(body.minX, 0) + 5
        inner.draw(text, at: CGPoint(x: labelX, y: body.minY + 2), anchor: .topLeading)

        strokeOutline(of: body, cornerRadius: 4, style: style, in: &context)
    }

    /// The volume envelope over an audio clip's waveform: the gain line (the clip's static gain,
    /// dragged vertically), the fade-in rising from silence at the clip start to the gain line and
    /// the fade-out falling back to silence at its end (its lane-0 fades), with the silenced area
    /// above the fades darkened.
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
            // The media the tile's middle shows (mirrored for a reversed clip; the cache is keyed by media time).
            var sourceTime = clip.isStill ? 0 : clip.mediaTime(atClipTime: clip.sourceIn + (timelineTime - clip.start) * clip.speed)
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
        // The media times at the visible edges (a reversed clip runs from the later one).
        let atLeft = clip.mediaTime(atClipTime: clip.sourceIn + (model.time(forX: x0) - clip.start) * speed)
        let atRight = clip.mediaTime(atClipTime: clip.sourceIn + (model.time(forX: x1) - clip.start) * speed)
        let first = max(0, Int((min(atLeft, atRight) / tileSeconds).rounded(.down)))
        let last = max(first, Int((max(atLeft, atRight) / tileSeconds).rounded(.down)))
        // The timeline x where media time `media` plays.
        func x(ofMedia media: Double) -> CGFloat {
            model.x(forTime: clip.start + (clip.mediaTime(atClipTime: media) - clip.sourceIn) / speed)
        }
        for index in first ... min(last, first + 256) {
            guard let image = waveforms.strip(asset: clip.assetID, level: level, index: index) else { continue }
            let tileStart = Double(index) * tileSeconds
            let a = x(ofMedia: tileStart)
            let b = x(ofMedia: tileStart + tileSeconds)
            let tile = CGRect(x: min(a, b), y: rect.minY, width: max(0.5, abs(b - a)), height: rect.height)
            if clip.reversed {
                // Played backwards: the strip drawn mirrored left to right.
                var mirrored = context
                mirrored.translateBy(x: tile.minX + tile.maxX, y: 0)
                mirrored.scaleBy(x: -1, y: 1)
                mirrored.draw(Image(decorative: image, scale: 1), in: tile)
            } else {
                context.draw(Image(decorative: image, scale: 1), in: tile)
            }
        }
    }

    /// Drop feedback for a transition dragged from the Effects tab: the cut or clip edge it would
    /// go on is highlighted on lane 0 with the span it would get, in the transitions' colour and
    /// labelled with what it becomes ("Cross Dissolve", or "Fade" on a free clip edge), or in red
    /// when it cannot take one, with the reason.
    private func drawDropTarget(_ target: TimelineGestureController.TransitionDropTarget,
                                in context: inout GraphicsContext, size: CGSize) {
        guard let layout = model.layout(forTrack: target.trackID) else { return }
        let top = layout.y - model.scrollY
        let color: Color = target.allowed ? Self.color(.transition) : .red
        let cutX = model.x(forTime: target.cut)
        context.stroke(Path { $0.move(to: CGPoint(x: cutX, y: top)); $0.addLine(to: CGPoint(x: cutX, y: top + layout.height)) },
                       with: .color(color), lineWidth: 2)
        if target.allowed, let lane = model.laneRect(track: target.trackID, lane: 0, width: size.width) {
            let x0 = model.x(forTime: target.start)
            let x1 = model.x(forTime: target.end)
            let band = CGRect(x: x0, y: lane.minY + 1, width: max(4, x1 - x0), height: lane.height - 2)
            context.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(color.opacity(0.6)))
            context.stroke(Path(roundedRect: band, cornerRadius: 3), with: .color(color), lineWidth: 1.5)
            var inner = context
            inner.clip(to: Path(band))
            let label = inner.resolve(Text(target.previewLabel).font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white))
            inner.draw(label, at: CGPoint(x: band.minX + 4, y: band.midY), anchor: .leading)
        }
        let text = target.message.isEmpty ? "\(target.title) · \(formatFrames(target.frames))" : target.message
        drawNote(text, at: CGPoint(x: cutX + 8, y: top + 2), color: target.allowed ? .black : .red, in: &context,
                 size: size)
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

/// The look of a clip, a span bar or a transition bar in the timeline, selected or not (hands-on round,
/// 2026-09-27: the selection was hard to see). Every kind follows the same rule: unselected, its fill at
/// `unselectedOpacity` with a thin dark outline on its edge and a white label; selected, the fill made
/// `selectionLightening` lighter (mixed that far towards white), opaque, with a `selectedBorderWidth` border
/// in the system accent colour inside the item (it never reaches past the item, so the hit geometry is
/// the same) and the label in white or black, whichever reads better on that fill (WCAG contrast).
struct TimelineItemStyle: Equatable {
    /// What is drawn.
    enum Kind: CaseIterable, Hashable {
        case videoClip, audioClip, missingClip, transition, motion, opacity, gain

        init(_ span: TimelineViewModel.SpanKind) {
            switch span {
            case .transition: self = .transition
            case .motion: self = .motion
            case .opacity: self = .opacity
            case .gain: self = .gain
            }
        }
    }

    /// An sRGB colour by its components (0...1), so styles compare and their contrast can be computed.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        /// Mixed `fraction` of the way towards white.
        func lightened(_ fraction: Double) -> RGB {
            RGB(red: red + (1 - red) * fraction, green: green + (1 - green) * fraction,
                blue: blue + (1 - blue) * fraction)
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG contrast ratio against `other` (1...21).
        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance + 0.05, other.luminance + 0.05)
            return max(a, b) / min(a, b)
        }

        var color: Color { Color(red: red, green: green, blue: blue) }

        static let white = RGB(red: 1, green: 1, blue: 1)
        static let black = RGB(red: 0, green: 0, blue: 0)
    }

    enum Border: Equatable {
        /// The system accent colour (`Color.accentColor`, `NSColor.controlAccentColor`).
        case accent
        /// Black at this opacity (the unselected hairline).
        case shade(Double)
    }

    /// How much lighter a selected item's fill is than its unselected fill.
    static let selectionLightening = 0.2
    /// The selected border's width, points; it lies inside the item.
    static let selectedBorderWidth: CGFloat = 2
    /// The fill's opacity when not selected (over the lane).
    static let unselectedOpacity = 0.85

    let fill: RGB
    let fillOpacity: Double
    let border: Border
    let borderWidth: CGFloat
    /// Label and icon colour.
    let label: RGB

    /// The fill of `kind` before selection.
    static func baseFill(_ kind: Kind) -> RGB {
        switch kind {
        case .videoClip: return RGB(red: 0.22, green: 0.32, blue: 0.58)
        case .audioClip: return RGB(red: 0.18, green: 0.42, blue: 0.28)
        case .missingClip: return RGB(red: 0.55, green: 0.18, blue: 0.18)
        case .transition: return RGB(red: 0.58, green: 0.34, blue: 0.80)
        case .motion: return RGB(red: 0.85, green: 0.52, blue: 0.16)
        case .opacity: return RGB(red: 0.2, green: 0.6, blue: 0.7)
        case .gain: return RGB(red: 0.55, green: 0.66, blue: 0.18)
        }
    }

    init(kind: Kind, selected: Bool) {
        let base = Self.baseFill(kind)
        if selected {
            fill = base.lightened(Self.selectionLightening)
            fillOpacity = 1
            border = .accent
            borderWidth = Self.selectedBorderWidth
            label = fill.contrast(with: .white) >= fill.contrast(with: .black) ? .white : .black
        } else {
            let clip = kind == .videoClip || kind == .audioClip || kind == .missingClip
            fill = base
            fillOpacity = Self.unselectedOpacity
            border = .shade(clip ? 0.5 : 0.35)
            borderWidth = clip ? 1 : 0.5
            label = .white
        }
    }

    /// How far the border's path is inside the item's edge: half its width for the selected border (so
    /// all of it is inside), none for the unselected hairline (drawn on the edge, as before).
    var borderInset: CGFloat { border == .accent ? borderWidth / 2 : 0 }

    var fillColor: Color { fill.color.opacity(fillOpacity) }

    var borderColor: Color {
        switch border {
        case .accent: return Color.accentColor
        case let .shade(opacity): return Color.black.opacity(opacity)
        }
    }

    var labelColor: Color { label.color }
}
