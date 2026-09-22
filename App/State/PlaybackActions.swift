import CoreMedia
import Foundation

/// What the transport controls and the space/J/K/L keys ask of playback.
///
/// PLAYBACK INTEGRATION POINT: the playback phase provides an implementation backed by the
/// engine's playback controller and assigns it to `ProjectStore.playbackActions`. Until then
/// `PlaybackActionsPlaceholder` is installed: play/pause/shuttle do nothing, which is the
/// documented behaviour of this phase (the program monitor shows the still frame at the playhead).
@MainActor
protocol PlaybackActions: AnyObject {
    /// True while playing (drives the play/pause button).
    var isPlaying: Bool { get }
    func togglePlay()
    /// J: play backwards (repeat to go faster).
    func shuttleReverse()
    /// K: stop.
    func shuttleStop()
    /// L: play forwards (repeat to go faster).
    func shuttleForward()
}

/// No-op playback until the playback controller lands (see `PlaybackActions`).
@MainActor
final class PlaybackActionsPlaceholder: PlaybackActions {
    private(set) var isPlaying = false
    private(set) var requests: [String] = []

    func togglePlay() { requests.append("toggle") }
    func shuttleReverse() { requests.append("reverse") }
    func shuttleStop() { requests.append("stop") }
    func shuttleForward() { requests.append("forward") }
}
