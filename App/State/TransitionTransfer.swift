import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import FramewrightEngine

extension UTType {
    /// A Cross Dissolve dragged from the Transitions panel (declared in Info.plist). Each kind
    /// has its own type so the timeline can tell what is dragged before the drop (the payload
    /// itself is only readable after it).
    static let framewrightCrossDissolve = UTType(exportedAs: "com.justjohn12345.framewright.transition.cross-dissolve")
    /// A Constant Power crossfade dragged from the Transitions panel (declared in Info.plist).
    static let framewrightAudioCrossfade = UTType(exportedAs: "com.justjohn12345.framewright.transition.audio-crossfade")
}

/// The transitions of the MVP: one per track kind.
enum TransitionKind: String, CaseIterable, Identifiable, Codable {
    /// Video: a linear dissolve between the two pictures.
    case crossDissolve
    /// Audio: a constant-power crossfade (sin/cos gain curves).
    case audioCrossfade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossDissolve: return "Cross Dissolve"
        case .audioCrossfade: return "Constant Power"
        }
    }

    var detail: String {
        switch self {
        case .crossDissolve: return "Video"
        case .audioCrossfade: return "Audio crossfade"
        }
    }

    var systemImage: String {
        switch self {
        case .crossDissolve: return "square.on.square.dashed"
        case .audioCrossfade: return "waveform.path"
        }
    }

    var trackKind: VETrackKind {
        switch self {
        case .crossDissolve: return .video
        case .audioCrossfade: return .audio
        }
    }

    var contentType: UTType {
        switch self {
        case .crossDissolve: return .framewrightCrossDissolve
        case .audioCrossfade: return .framewrightAudioCrossfade
        }
    }

    /// The kind of transition on a track of `kind`.
    static func forTrack(_ kind: VETrackKind) -> TransitionKind {
        kind == .video ? .crossDissolve : .audioCrossfade
    }
}

/// Drag payload of the Transitions panel. Only meaningful inside this app process.
struct TransitionReference: Codable, Transferable, Hashable {
    let kind: TransitionKind

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .framewrightCrossDissolve)
            .exportingCondition { $0.kind == .crossDissolve }
        CodableRepresentation(contentType: .framewrightAudioCrossfade)
            .exportingCondition { $0.kind == .audioCrossfade }
    }
}

/// A transition waiting for the answer to "also add the crossfade on the linked audio?".
struct PendingTransition: Equatable {
    let kind: TransitionKind
    let fromClipID: VEClipID
    let toClipID: VEClipID
    let frames: Int64
}

/// A request for the inspector to focus one of its fields (`serial` makes repeats distinct).
struct InspectorFocusRequest: Equatable {
    enum Field: Equatable {
        case transitionDuration
    }

    let field: Field
    let serial: Int
}
