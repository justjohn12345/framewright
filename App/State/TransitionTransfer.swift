import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import FramewrightEngine

extension UTType {
    /// A Cross Dissolve dragged from the Transitions panel (declared in Info.plist). Each kind
    /// has its own type so the timeline can tell what is dragged before the drop (the payload
    /// itself is only readable after it).
    static let framewrightCrossDissolve = UTType(exportedAs: "com.justjohn12345.framewright.transition.cross-dissolve")
    /// The wipes and the iris dragged from the Transitions panel (declared in Info.plist).
    static let framewrightWipeLeft = UTType(exportedAs: "com.justjohn12345.framewright.transition.wipe-left")
    static let framewrightWipeRight = UTType(exportedAs: "com.justjohn12345.framewright.transition.wipe-right")
    static let framewrightWipeUp = UTType(exportedAs: "com.justjohn12345.framewright.transition.wipe-up")
    static let framewrightWipeDown = UTType(exportedAs: "com.justjohn12345.framewright.transition.wipe-down")
    static let framewrightIris = UTType(exportedAs: "com.justjohn12345.framewright.transition.iris")
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
        case .kenBurns: return "Pan and zoom inside the frame"
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

/// The transitions of the Effects tab: the video kinds (VETransitionKind: a cross dissolve, four
/// wipes and the iris; across a cut or, at a clip's free start or end, from or to black) and the
/// audio crossfade (a constant-power crossfade across a cut, a fade from or to silence at a free
/// edge). The wipes are named for the direction the edge between the pictures travels: Wipe Left
/// brings the incoming picture in from the right edge.
enum TransitionKind: String, CaseIterable, Identifiable, Codable {
    /// Video: a linear dissolve between the two pictures.
    case crossDissolve
    /// Video: the incoming picture enters from the right edge; the edge travels left.
    case wipeLeft
    /// Video: the incoming picture enters from the left edge; the edge travels right.
    case wipeRight
    /// Video: the incoming picture enters from the bottom edge; the edge travels up.
    case wipeUp
    /// Video: the incoming picture enters from the top edge; the edge travels down.
    case wipeDown
    /// Video: the incoming picture shows inside a circle growing from the frame's centre; at a clip's
    /// end (a fade to black) the circle closes on the picture instead.
    case iris
    /// Audio: a constant-power crossfade (sin/cos gain curves).
    case audioCrossfade

    var id: String { rawValue }

    /// The kinds a video transition can have (the inspector's Kind popup), in the Effects tab's order.
    static let videoKinds: [TransitionKind] = [.crossDissolve, .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .iris]

    var title: String {
        switch self {
        case .crossDissolve: return "Cross Dissolve"
        case .wipeLeft: return "Wipe Left"
        case .wipeRight: return "Wipe Right"
        case .wipeUp: return "Wipe Up"
        case .wipeDown: return "Wipe Down"
        case .iris: return "Iris"
        case .audioCrossfade: return "Constant Power"
        }
    }

    var detail: String {
        switch self {
        case .crossDissolve: return "Video"
        case .wipeLeft: return "Video: enters from the right"
        case .wipeRight: return "Video: enters from the left"
        case .wipeUp: return "Video: enters from the bottom"
        case .wipeDown: return "Video: enters from the top"
        case .iris: return "Video: a circle opening from the centre; closes at a clip's end"
        case .audioCrossfade: return "Audio crossfade"
        }
    }

    var systemImage: String {
        switch self {
        case .crossDissolve: return "square.on.square.dashed"
        case .wipeLeft: return "arrow.left.square"
        case .wipeRight: return "arrow.right.square"
        case .wipeUp: return "arrow.up.square"
        case .wipeDown: return "arrow.down.square"
        case .iris: return "circle.dashed"
        case .audioCrossfade: return "waveform.path"
        }
    }

    /// The small mark drawn before a shaped transition's name on the timeline: the way the edge
    /// travels (a wipe) or a circle (the iris); nil for the dissolve and the audio crossfade.
    var glyph: String? {
        switch self {
        case .crossDissolve, .audioCrossfade: return nil
        case .wipeLeft: return "◁"
        case .wipeRight: return "▷"
        case .wipeUp: return "△"
        case .wipeDown: return "▽"
        case .iris: return "◯"
        }
    }

    var trackKind: VETrackKind {
        self == .audioCrossfade ? .audio : .video
    }

    /// The engine's kind (the audio crossfade has none: CrossDissolve).
    var engineKind: VETransitionKind {
        switch self {
        case .crossDissolve, .audioCrossfade: return .crossDissolve
        case .wipeLeft: return .wipeLeft
        case .wipeRight: return .wipeRight
        case .wipeUp: return .wipeUp
        case .wipeDown: return .wipeDown
        case .iris: return .iris
        }
    }

    /// The kind of a transition on a track of `trackKind` whose engine kind is `engineKind`: the
    /// audio crossfade on an audio track, else the video kind.
    init(engineKind: VETransitionKind, trackKind: VETrackKind) {
        guard trackKind == .video else {
            self = .audioCrossfade
            return
        }
        switch engineKind {
        case .wipeLeft: self = .wipeLeft
        case .wipeRight: self = .wipeRight
        case .wipeUp: self = .wipeUp
        case .wipeDown: self = .wipeDown
        case .iris: self = .iris
        default: self = .crossDissolve
        }
    }

    var contentType: UTType {
        switch self {
        case .crossDissolve: return .framewrightCrossDissolve
        case .wipeLeft: return .framewrightWipeLeft
        case .wipeRight: return .framewrightWipeRight
        case .wipeUp: return .framewrightWipeUp
        case .wipeDown: return .framewrightWipeDown
        case .iris: return .framewrightIris
        case .audioCrossfade: return .framewrightAudioCrossfade
        }
    }

    /// The kind of transition a track of `kind` gets by default (Add Cross Dissolve / Add Audio
    /// Crossfade).
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
        CodableRepresentation(contentType: .framewrightWipeLeft)
            .exportingCondition { $0.kind == .wipeLeft }
        CodableRepresentation(contentType: .framewrightWipeRight)
            .exportingCondition { $0.kind == .wipeRight }
        CodableRepresentation(contentType: .framewrightWipeUp)
            .exportingCondition { $0.kind == .wipeUp }
        CodableRepresentation(contentType: .framewrightWipeDown)
            .exportingCondition { $0.kind == .wipeDown }
        CodableRepresentation(contentType: .framewrightIris)
            .exportingCondition { $0.kind == .iris }
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
        /// The selected title's text, with all of it selected (a title just added: typing replaces its placeholder).
        case titleText
    }

    let field: Field
    let serial: Int
}
