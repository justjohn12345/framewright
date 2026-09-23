import SwiftUI
import FramewrightEngine

/// Header of one track row: name, target indicator, mute/solo/lock toggles.
struct TrackHeaderView: View {
    @ObservedObject var store: ProjectStore
    let track: TimelineViewModel.Track
    let height: CGFloat

    private var isTarget: Bool {
        track.kind == .video ? store.targetVideoTrackID == track.id : store.targetAudioTrackID == track.id
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if track.kind == .video {
                    store.targetVideoTrackID = track.id
                } else {
                    store.targetAudioTrackID = track.id
                }
            } label: {
                Text(track.name)
                    .font(.caption.weight(.semibold))
                    .frame(width: 34, height: 20)
                    .background(isTarget ? Color.accentColor : Color.secondary.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(isTarget ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
            .help("Target track for Insert/Overwrite from the source monitor")
            Spacer(minLength: 0)
            toggle(isOn: track.muted, on: track.kind == .video ? "eye.slash.fill" : "speaker.slash.fill",
                   off: track.kind == .video ? "eye" : "speaker.wave.2",
                   help: track.kind == .video ? "Hide track" : "Mute track") {
                store.report(store.engine.setTrack(track.id, muted: !track.muted))
            }
            toggle(isOn: track.solo, on: "s.square.fill", off: "s.square", help: "Solo track") {
                store.report(store.engine.setTrack(track.id, solo: !track.solo))
            }
            toggle(isOn: track.locked, on: "lock.fill", off: "lock.open", help: "Lock track") {
                store.report(store.engine.setTrack(track.id, locked: !track.locked))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: height)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Button("Delete Track \(track.name)") {
                store.report(store.engine.removeTrack(track.id))
            }
        }
    }

    private func toggle(isOn: Bool, on: String, off: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? on : off)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
