import CoreMedia
import CoreTransferable
import Foundation
import FramewrightEngine
import UniformTypeIdentifiers

extension UTType {
    /// The Effects tab's Title, Lower Third and Colour Matte tiles dragged onto a track (declared in Info.plist; one
    /// type per preset, as for the transitions, so the timeline knows what is dragged before the drop).
    static let framewrightTitleGenerator = UTType(exportedAs: "com.justjohn12345.framewright.generator.title")
    static let framewrightLowerThirdGenerator = UTType(exportedAs: "com.justjohn12345.framewright.generator.lower-third")
    static let framewrightColourMatteGenerator = UTType(exportedAs: "com.justjohn12345.framewright.generator.colour-matte")
    static let framewrightTitleCardGenerator = UTType(exportedAs: "com.justjohn12345.framewright.generator.title-card")
    static let framewrightCaptionGenerator = UTType(exportedAs: "com.justjohn12345.framewright.generator.caption")
}

/// What a new title or matte starts as (the engine's presets, titles design section 9): a centred title, a lower
/// third (left-aligned in the lower left inside title-safe, "Name" and "Role" on a 60 % black box), a black colour
/// matte, a title card (a bold centred title over a black matte, two clips) and a caption (text at the top left of
/// title-safe that grows down and to the right as it is typed). Added from the Clip menu (Add Title ⌃T, Add Lower
/// Third ⇧⌃T, Add Colour Matte, Add Title Card, Add Caption) and the Effects tab's "Titles and Generators" tiles
/// (dragged onto a track, or "+" at the playhead).
enum GeneratorPreset: String, CaseIterable, Identifiable, Codable {
    case title
    case lowerThird
    case colourMatte
    case titleCard
    case caption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "Title"
        case .lowerThird: return "Lower Third"
        case .colourMatte: return "Colour Matte"
        case .titleCard: return "Title Card"
        case .caption: return "Caption"
        }
    }

    var detail: String {
        switch self {
        case .title: return "Centred text over the picture"
        case .lowerThird: return "Name and role on a box, lower left"
        case .colourMatte: return "A solid colour filling the frame"
        case .titleCard: return "A bold title over a black matte"
        case .caption: return "Top left, grows as you type"
        }
    }

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .lowerThird: return "text.below.photo"
        case .colourMatte: return "square.fill"
        case .titleCard: return "rectangle.inset.filled"
        case .caption: return "text.alignleft"
        }
    }

    var enginePreset: VEGeneratedPreset {
        switch self {
        case .title: return .title
        case .lowerThird: return .lowerThird
        case .colourMatte: return .colourMatte
        case .titleCard: return .titleCard
        case .caption: return .caption
        }
    }

    var contentType: UTType {
        switch self {
        case .title: return .framewrightTitleGenerator
        case .lowerThird: return .framewrightLowerThirdGenerator
        case .colourMatte: return .framewrightColourMatteGenerator
        case .titleCard: return .framewrightTitleCardGenerator
        case .caption: return .framewrightCaptionGenerator
        }
    }
}

/// Drag payload of the Effects tab's title and generator tiles. Only meaningful inside this app process.
struct GeneratorReference: Codable, Transferable, Hashable {
    let preset: GeneratorPreset

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .framewrightTitleGenerator)
            .exportingCondition { $0.preset == .title }
        CodableRepresentation(contentType: .framewrightLowerThirdGenerator)
            .exportingCondition { $0.preset == .lowerThird }
        CodableRepresentation(contentType: .framewrightColourMatteGenerator)
            .exportingCondition { $0.preset == .colourMatte }
        CodableRepresentation(contentType: .framewrightTitleCardGenerator)
            .exportingCondition { $0.preset == .titleCard }
        CodableRepresentation(contentType: .framewrightCaptionGenerator)
            .exportingCondition { $0.preset == .caption }
    }
}

extension ProjectStore {
    /// Whether a title or matte can be added now (the Clip menu's items, the tiles' "+"): not during a drag. (A
    /// sequence without a video track gets one with the title.)
    var canAddGenerated: Bool { !isGestureActive }

    /// Clip > Add Title (⌃T), Add Lower Third (⇧⌃T), Add Colour Matte and the tiles' "+": `preset` at the playhead,
    /// 5 s long, on the lowest video track above the target video track that is free for that time (a new track on
    /// top when none is), overwriting nothing; one undo step. The new clip is selected and, for a title, the
    /// inspector's text gets the focus with its placeholder selected, so typing replaces it.
    @discardableResult
    func addGenerated(_ preset: GeneratorPreset) -> Bool {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return false
        }
        inspector.endNudgeBurst()
        let target = videoTracks.contains { $0.trackID == targetVideoTrackID } ? targetVideoTrackID : 0
        let result = engine.addGenerated(preset.enginePreset, at: frameTime(playheadTime.secondsOrZero),
                                         aboveTrack: target)
        guard report(result), let id = result.createdIDs.first?.int64Value else { return false }
        selectNewGenerated(id, preset)
        return true
    }

    /// A title or matte tile dropped on the row `trackID` at `seconds`: overwrites what is under it there, or with
    /// `insert` (Command held) ripples the later clips right, as media dropped from the bin does. One undo step.
    @discardableResult
    func dropGenerated(_ preset: GeneratorPreset, onTrack trackID: VETrackID, at seconds: Double, insert: Bool) -> Bool {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return false
        }
        guard let track = track(trackID), track.kind == .video else {
            statusMessage = "Drop a \(preset.title.lowercased()) on a video track."
            return false
        }
        inspector.endNudgeBurst()
        let result = engine.placeGenerated(preset.enginePreset, onTrack: track.trackID, at: frameTime(max(0, seconds)),
                                           insert: insert)
        guard report(result), let id = result.createdIDs.first?.int64Value else { return false }
        selectNewGenerated(id, preset)
        return true
    }

    private func selectNewGenerated(_ id: VEClipID, _ preset: GeneratorPreset) {
        selection = [id]
        focusArea = .timeline
        if preset == .colourMatte {
            layout.inspectorTab = .inspector
        } else {
            requestInspectorFocus(.titleText)
        }
    }
}
