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
    /// A Fade (a video Opacity span) dragged from the Effects tab (declared in Info.plist).
    static let framewrightFadeEffect = UTType(exportedAs: "com.justjohn12345.framewright.effect.fade")
    /// A Gain span (audio) dragged from the Effects tab (declared in Info.plist).
    static let framewrightGainEffect = UTType(exportedAs: "com.justjohn12345.framewright.effect.gain")
    /// A Ken Burns Motion span dragged from the Effects tab (declared in Info.plist).
    static let framewrightKenBurnsEffect = UTType(exportedAs: "com.justjohn12345.framewright.effect.ken-burns")
    /// A Move (a Motion span that starts still) dragged from the Effects tab (declared in Info.plist).
    static let framewrightMoveEffect = UTType(exportedAs: "com.justjohn12345.framewright.effect.move")
}

/// The effects of the Effects tab that go on an effect lane (1-3) of a clip: Ken Burns and Move
/// (Motion spans on a video clip, with the intent recorded as the mode their Ken Burns editor opens
/// in), a Fade (an Opacity span on a video clip) and a Gain span (an audio clip).
enum EffectKind: String, CaseIterable, Identifiable, Codable {
    case kenBurns
    case move
    case fade
    case gain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kenBurns: return "Ken Burns"
        case .move: return "Move"
        case .fade: return "Fade"
        case .gain: return "Gain"
        }
    }

    var detail: String {
        switch self {
        case .kenBurns: return "Pan and zoom inside the picture"
        case .move: return "Move or scale the clip in the frame"
        case .fade: return "Video opacity span"
        case .gain: return "Audio level span"
        }
    }

    var systemImage: String {
        switch self {
        case .kenBurns: return "crop"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .fade: return "circle.lefthalf.filled"
        case .gain: return "speaker.wave.2"
        }
    }

    var trackKind: VETrackKind {
        switch self {
        case .kenBurns, .move, .fade: return .video
        case .gain: return .audio
        }
    }

    /// The span it adds.
    var spanKind: VESpanKind {
        switch self {
        case .kenBurns, .move: return .motion
        case .fade: return .opacity
        case .gain: return .gain
        }
    }

    /// The mode a Motion span it adds opens its Ken Burns editor in (nil for the other kinds): Ken
    /// Burns (the push in: the End rectangle 1 / 1.25 of the frame, centred) or Transform (Move: the
    /// End where the Start is, nothing moves until a box is dragged).
    var motionMode: KenBurnsMode? {
        switch self {
        case .kenBurns: return .kenBurns
        case .move: return .transform
        case .fade, .gain: return nil
        }
    }

    var contentType: UTType {
        switch self {
        case .kenBurns: return .framewrightKenBurnsEffect
        case .move: return .framewrightMoveEffect
        case .fade: return .framewrightFadeEffect
        case .gain: return .framewrightGainEffect
        }
    }
}

/// Drag payload of the Effects tab's effects. Only meaningful inside this app process.
struct EffectReference: Codable, Transferable, Hashable {
    let kind: EffectKind

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .framewrightFadeEffect)
            .exportingCondition { $0.kind == .fade }
        CodableRepresentation(contentType: .framewrightGainEffect)
            .exportingCondition { $0.kind == .gain }
        CodableRepresentation(contentType: .framewrightKenBurnsEffect)
            .exportingCondition { $0.kind == .kenBurns }
        CodableRepresentation(contentType: .framewrightMoveEffect)
            .exportingCondition { $0.kind == .move }
    }
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
