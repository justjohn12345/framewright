import SwiftUI
import FramewrightEngine

/// Header of one track row: the disclosure (an empty track collapses its row, a track with clips
/// its lanes), name, target indicator, mute/solo/lock toggles, and below them the names of the
/// lanes shown (Transitions for lane 0, Effects 1-3).
struct TrackHeaderView: View {
    @ObservedObject var store: ProjectStore
    let track: TimelineViewModel.Track
    /// The row and its lanes.
    let height: CGFloat
    /// The row of clips.
    var rowHeight: CGFloat? = nil

    /// The disclosure's state: collapsed (pointing right) or expanded.
    private var isCollapsed: Bool { track.isEmpty ? track.collapsed : track.lanesCollapsed }

    private var disclosureHelp: String {
        if track.isEmpty {
            return track.collapsed ? "Expand track \(track.name)" : "Collapse the empty track \(track.name)"
        }
        return track.lanesCollapsed ? "Show the lanes of track \(track.name) (transitions and effect spans)"
            : "Hide the lanes of track \(track.name)"
    }

    private var isTarget: Bool {
        track.kind == .video ? store.targetVideoTrackID == track.id : store.targetAudioTrackID == track.id
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .frame(height: rowHeight ?? height)
            ForEach(track.lanes, id: \.self) { lane in
                Text(lane == 0 ? "Transitions" : "Effects \(lane)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
                    .frame(height: TimelineViewModel.laneHeight)
                    .background(Color.primary.opacity(lane == 0 ? 0.07 : 0.045))
            }
        }
        .frame(height: height, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Button("Delete Track \(track.name)") {
                store.report(store.engine.removeTrack(track.id))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button {
                store.toggleDisclosure(ofTrack: track.id)
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 12, height: 18)
            }
            .buttonStyle(.plain)
            .help(disclosureHelp)
            .accessibilityIdentifier("TrackCollapse.\(track.name)")
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
