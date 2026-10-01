import FramewrightEngine

// The names and icons of span and transition kinds, in one place (review B11 of the 2026-10-01 general
// review: the timeline knew the wipes and the iris, while the status line, the drop notes and the
// inspector called every transition a cross dissolve or crossfade). The timeline's bars, the inspector,
// the Ken Burns editor, the drag status lines and the drop notes all read these.

extension TimelineViewModel.SpanKind {
    /// The kind of an engine span.
    init(_ kind: VESpanKind) {
        switch kind {
        case .transition: self = .transition
        case .motion: self = .motion
        case .opacity: self = .opacity
        case .gain: self = .gain
        @unknown default: self = .motion
        }
    }

    /// "Motion", "Fade" or "Gain"; a transition is named by its kind and where it sits
    /// (`TransitionKind.title(style:)`).
    func title(style: TimelineViewModel.TransitionStyle, transitionKind: TransitionKind) -> String {
        switch self {
        case .motion: return "Motion"
        case .opacity: return "Fade"
        case .gain: return "Gain"
        case .transition: return transitionKind.title(style: style)
        }
    }

    /// The SF Symbol of the kind (a transition's by where it sits and whether it is audio).
    func systemImage(style: TimelineViewModel.TransitionStyle, transitionKind: TransitionKind) -> String {
        switch self {
        case .motion: return "arrow.up.left.and.arrow.down.right"
        case .opacity: return "circle.lefthalf.filled"
        case .gain: return "speaker.wave.2"
        case .transition:
            switch style {
            case .crossDissolve: return transitionKind == .audioCrossfade ? "waveform.path" : "square.on.square.dashed"
            case .fadeIn: return "arrow.up.right"
            case .fadeOut: return "arrow.down.right"
            }
        }
    }
}

extension TimelineViewModel.TransitionStyle {
    /// Where an engine transition sits.
    init(_ style: VETransitionStyle) {
        switch style {
        case .fadeIn: self = .fadeIn
        case .fadeOut: self = .fadeOut
        default: self = .crossDissolve
        }
    }
}

extension TransitionKind {
    /// The name of a transition of this kind sitting as `style`. A wipe or the iris is named for its kind,
    /// with In or Out at a clip's free start or end (from or to black): "Wipe Left", "Iris Out". A dissolve
    /// is a "Cross Dissolve" (on an audio track a "Crossfade"), at a free edge a "Fade In" or "Fade Out".
    func title(style: TimelineViewModel.TransitionStyle) -> String {
        if glyph != nil {
            switch style {
            case .crossDissolve: return title
            case .fadeIn: return title + " In"
            case .fadeOut: return title + " Out"
            }
        }
        switch style {
        case .crossDissolve: return self == .audioCrossfade ? "Crossfade" : "Cross Dissolve"
        case .fadeIn: return "Fade In"
        case .fadeOut: return "Fade Out"
        }
    }

    /// The same name inside a sentence: a wipe or the iris keeps its capitals ("the Iris Out"), the others
    /// read as words ("the cross dissolve", "the fade in").
    func sentenceTitle(style: TimelineViewModel.TransitionStyle) -> String {
        glyph != nil ? title(style: style) : title(style: style).lowercased()
    }
}

extension VEEffectSpan {
    /// The span's kind, where it sits (transitions) and what it does on a track of `trackKind`.
    func display(onTrackKind trackKind: VETrackKind) -> (kind: TimelineViewModel.SpanKind,
                                                         style: TimelineViewModel.TransitionStyle,
                                                         transitionKind: TransitionKind) {
        (TimelineViewModel.SpanKind(kind), TimelineViewModel.TransitionStyle(transitionStyle),
         TransitionKind(engineKind: transitionKind, trackKind: trackKind))
    }

    /// The span's title ("Motion", "Wipe Left", "Iris Out", "Crossfade") on a track of `trackKind`.
    func title(onTrackKind trackKind: VETrackKind) -> String {
        let display = display(onTrackKind: trackKind)
        return display.kind.title(style: display.style, transitionKind: display.transitionKind)
    }

    /// The span's SF Symbol on a track of `trackKind`.
    func systemImage(onTrackKind trackKind: VETrackKind) -> String {
        let display = display(onTrackKind: trackKind)
        return display.kind.systemImage(style: display.style, transitionKind: display.transitionKind)
    }
}
