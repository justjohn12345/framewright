import CoreMedia
import Foundation
import VidEditEngine

/// Position and transport state of one monitor (program or source), published separately from
/// `ProjectStore` so a playhead moving at the display rate only redraws the views that show it
/// (playhead line, timecodes, the play button), never the timeline or the rest of the window.
@MainActor
final class PlayheadModel: ObservableObject {
    /// On the monitor's frame grid. Driven by the engine while playing; `ProjectStore` sets it
    /// immediately when the user moves it (the engine's report follows).
    @Published private(set) var time: CMTime = .zero
    @Published private(set) var state: VEPlaybackState = .stopped
    /// Signed shuttle rate (1, 2, 4, 8, -1, ...), meaningful while running.
    @Published private(set) var rate: Double = 1
    /// The engine's last audio problem ("" when none).
    @Published private(set) var errorMessage = ""

    /// Number of time changes published (diagnostics and tests).
    private(set) var timeUpdates = 0

    /// Playing or pre-rolling: the monitor's render loop runs.
    var isRunning: Bool { state == .playing || state == .prerolling }

    /// Applies an engine status (publishes only what changed).
    func apply(_ status: VEPlaybackStatus) {
        setTime(status.time)
        if state != status.state { state = status.state }
        if rate != status.rate { rate = status.rate }
        if errorMessage != status.errorMessage { errorMessage = status.errorMessage }
    }

    /// Moves the playhead without asking the engine (the caller already did).
    func setTime(_ newTime: CMTime) {
        guard newTime != time else { return }
        time = newTime
        timeUpdates += 1
    }

    func reset() {
        setTime(.zero)
        if state != .stopped { state = .stopped }
        if rate != 1 { rate = 1 }
        if !errorMessage.isEmpty { errorMessage = "" }
    }
}

/// Zoom and scroll of the timeline, published separately from the model so scrolling redraws
/// only the timeline.
@MainActor
final class TimelineViewport: ObservableObject {
    @Published var pixelsPerSecond: Double = 50
    @Published var scrollX: CGFloat = 0
    @Published var scrollY: CGFloat = 0
}

/// What the transport controls, the Playback menu and the space/J/K/L/arrow keys ask of
/// playback. `ProjectStore.playbackActions` is the engine-backed implementation; the monitor
/// that last had the user's attention (`ProjectStore.focusArea`) receives the request.
@MainActor
protocol PlaybackActions: AnyObject {
    /// True while the focused monitor plays (drives the play/pause button).
    var isPlaying: Bool { get }
    func togglePlay()
    /// J: play backwards (repeat to go faster).
    func shuttleReverse()
    /// K: stop.
    func shuttleStop()
    /// L: play forwards (repeat to go faster).
    func shuttleForward()
    /// ←/→: pause and move by frames.
    func stepFrames(_ count: Int)
    /// Home / End.
    func goToStart()
    func goToEnd()
}

/// Playback over the engine: the program monitor's controller, or the source monitor's when
/// the source monitor has focus.
@MainActor
final class EnginePlaybackActions: PlaybackActions {
    private weak var store: ProjectStore?

    init(store: ProjectStore) {
        self.store = store
    }

    private var sourceFocused: Bool {
        guard let store else { return false }
        return store.focusArea == .sourceMonitor && store.source.assetID != nil
    }

    var isPlaying: Bool {
        guard let store else { return false }
        return sourceFocused ? store.sourcePlayhead.isRunning : store.playhead.isRunning
    }

    func togglePlay() {
        guard let store else { return }
        if sourceFocused {
            store.engine.sourceMonitorTogglePlay()
        } else {
            store.engine.togglePlay()
        }
    }

    func shuttleReverse() {
        guard let store else { return }
        if sourceFocused {
            store.engine.sourceMonitorShuttleReverse()
        } else {
            store.engine.shuttleReverse()
        }
    }

    func shuttleStop() {
        guard let store else { return }
        if sourceFocused {
            store.engine.sourceMonitorPause()
        } else {
            store.engine.shuttleStop()
        }
    }

    func shuttleForward() {
        guard let store else { return }
        if sourceFocused {
            store.engine.sourceMonitorShuttleForward()
        } else {
            store.engine.shuttleForward()
        }
    }

    func stepFrames(_ count: Int) {
        guard let store else { return }
        if sourceFocused {
            store.engine.sourceMonitorStepFrames(count)
        } else {
            store.stepFrames(count)
        }
    }

    func goToStart() {
        guard let store else { return }
        if sourceFocused {
            store.scrubSource(to: .zero)
        } else {
            store.playheadTime = .zero
        }
    }

    func goToEnd() {
        guard let store else { return }
        if sourceFocused {
            store.scrubSource(to: store.sourceDuration)
        } else {
            // The last frame (the sequence end itself shows nothing).
            let end = store.sequence.duration
            store.playheadTime = end > store.frameDuration ? CMTimeSubtract(end, store.frameDuration) : .zero
        }
    }
}
