import AppKit
import Combine
import CoreMedia
import Foundation
import VidEditEngine

/// Source monitor state: the asset shown, the scrub position and the in/out marks.
struct SourceMonitorState: Equatable {
    var assetID: VEAssetID?
    var time: CMTime = .zero
    var inPoint: CMTime?
    var outPoint: CMTime?
}

/// Which panel the user worked in last (decides what Delete removes).
enum FocusArea {
    case timeline
    case mediaBin
}

/// The app's single source of truth over the engine (`VEEngine`).
///
/// It republishes engine snapshots (sequence, tracks, clips, assets, undo state) whenever the
/// engine's model changes, and owns UI state: selection, playhead, zoom/scroll, the source
/// monitor and track targeting. Every edit goes through the engine; a refused edit leaves a
/// message in `statusMessage`.
///
/// PLAYBACK INTEGRATION POINTS
/// - `playheadTime` is owned and published here. The playback controller should drive it while
///   playing (and observe it for seeks when stopped).
/// - `playbackActions` receives play/pause/J/K/L; replace the placeholder with the controller.
/// - `attachProgramView(_:)` hands the program monitor's `VEPreviewView` to the engine, which
///   installs the still-frame source; the playback controller installs its own source there.
@MainActor
final class ProjectStore: ObservableObject {
    let engine: VEEngine
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache
    var playbackActions: PlaybackActions = PlaybackActionsPlaceholder()

    // Engine snapshots.
    @Published private(set) var sequence: VESequenceInfo
    @Published private(set) var tracks: [VETrackInfo] = []
    @Published private(set) var clips: [VEClipID: VEClipInfo] = [:]
    @Published private(set) var assets: [VEAssetInfo] = []
    @Published private(set) var changeCount: UInt64 = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoActionName = ""
    @Published private(set) var redoActionName = ""
    @Published private(set) var isDirty = false
    @Published private(set) var projectURL: URL?
    @Published private(set) var projectName = "Untitled"
    @Published private(set) var isImporting = false

    // UI state.
    @Published var selection: Set<VEClipID> = []
    @Published var selectedAssetID: VEAssetID?
    @Published var selectedTransitionID: VETransitionID?
    @Published var playheadTime: CMTime = .zero {
        didSet {
            if playheadTime != oldValue {
                engine.showProgramFrame(at: playheadTime)
            }
        }
    }

    @Published var pixelsPerSecond: Double = 50
    @Published var scrollX: CGFloat = 0
    @Published var scrollY: CGFloat = 0
    @Published var source = SourceMonitorState()
    @Published var targetVideoTrackID: VETrackID = 0
    @Published var targetAudioTrackID: VETrackID = 0
    @Published var focusArea: FocusArea = .timeline
    /// Last refused edit or import problem, shown in the transport bar.
    @Published var statusMessage: String?
    /// The snap line shown while dragging (seconds), or nil.
    @Published var snapIndicator: Double?

    /// Width of the timeline's track area, for Zoom to Fit (updated by the timeline).
    var timelineViewportWidth: CGFloat = 800

    /// Cancels the timeline gesture in progress (set by the timeline while dragging).
    var cancelActiveGesture: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(engine: VEEngine = VEEngine()) {
        self.engine = engine
        thumbnails = ThumbnailCache(engine: engine)
        waveforms = WaveformCache(engine: engine)
        sequence = engine.sequence
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .VEEngineModelDidChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModel() }
        })
        observers.append(center.addObserver(forName: .VEEngineAssetsDidChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAssets() }
        })
        refreshAssets()
        refreshModel()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Snapshots

    /// Re-reads the sequence, tracks, clips and undo state from the engine.
    func refreshModel() {
        sequence = engine.sequence
        tracks = engine.allTracks
        var byID: [VEClipID: VEClipInfo] = [:]
        for clip in engine.allClips {
            byID[clip.clipID] = clip
        }
        clips = byID
        selection = selection.filter { byID[$0] != nil }
        if let transition = selectedTransitionID, engine.transitionInfo(transition) == nil {
            selectedTransitionID = nil
        }
        changeCount = engine.changeCount
        canUndo = engine.canUndo
        canRedo = engine.canRedo
        undoActionName = engine.undoActionName
        redoActionName = engine.redoActionName
        isDirty = engine.isDirty
        projectURL = engine.projectURL
        projectName = engine.projectName
        let videoIDs = sequence.videoTrackIDs.map(\.int64Value)
        let audioIDs = sequence.audioTrackIDs.map(\.int64Value)
        if !videoIDs.contains(targetVideoTrackID) { targetVideoTrackID = videoIDs.first ?? 0 }
        if !audioIDs.contains(targetAudioTrackID) { targetAudioTrackID = audioIDs.first ?? 0 }
    }

    func refreshAssets() {
        assets = engine.allAssets
        let ids = Set(assets.map(\.assetID))
        if let selected = selectedAssetID, !ids.contains(selected) { selectedAssetID = nil }
        if let shown = source.assetID, !ids.contains(shown) { source = SourceMonitorState() }
    }

    func asset(_ id: VEAssetID) -> VEAssetInfo? {
        assets.first { $0.assetID == id }
    }

    func track(_ id: VETrackID) -> VETrackInfo? {
        tracks.first { $0.trackID == id }
    }

    var videoTracks: [VETrackInfo] { tracks.filter { $0.kind == .video } }
    var audioTracks: [VETrackInfo] { tracks.filter { $0.kind == .audio } }
    var frameDuration: CMTime { sequence.frameDuration }

    /// The selected clips, sorted by start.
    var selectedClips: [VEClipInfo] {
        selection.compactMap { clips[$0] }.sorted { $0.timelineStart < $1.timelineStart }
    }

    /// The geometry model for the timeline at the current zoom and scroll.
    var timelineModel: TimelineViewModel {
        var model = TimelineViewModel()
        model.pixelsPerSecond = pixelsPerSecond
        model.scrollX = scrollX
        model.scrollY = scrollY
        model.frameSeconds = frameDuration.secondsOrZero
        model.playhead = playheadTime.secondsOrZero
        model.tracks = tracks.map {
            TimelineViewModel.Track(id: $0.trackID, kind: $0.kind == .video ? .video : .audio, index: $0.index,
                                    name: $0.name, muted: $0.muted, solo: $0.solo, locked: $0.locked)
        }
        model.clips = clips.values.map {
            TimelineViewModel.Clip(id: $0.clipID, trackID: $0.trackID, assetID: $0.assetID, name: $0.name,
                                   start: $0.timelineStart.secondsOrZero, end: $0.timelineEnd.secondsOrZero,
                                   sourceIn: $0.sourceIn.secondsOrZero, speed: $0.speed,
                                   linkedClipID: $0.linkedClipID, isStill: $0.isStill)
        }.sorted { $0.start < $1.start }
        model.transitions = sequence.transitions.map {
            TimelineViewModel.Transition(id: $0.transitionID, trackID: $0.trackID, start: $0.start.secondsOrZero,
                                         end: $0.end.secondsOrZero)
        }
        return model
    }

    /// Converts seconds to a CMTime on the sequence frame grid.
    func frameTime(_ seconds: Double) -> CMTime {
        CMTime.onFrameGrid(seconds: seconds, frameDuration: frameDuration)
    }

    // MARK: Edit helpers

    /// Reports a refused edit; returns whether it succeeded.
    @discardableResult
    func report(_ result: VEEditResult) -> Bool {
        statusMessage = result.ok ? nil : result.message
        return result.ok
    }

    func undo() {
        cancelActiveGesture?()
        _ = engine.undo()
    }

    func redo() {
        cancelActiveGesture?()
        _ = engine.redo()
    }

    // MARK: Program monitor

    func attachProgramView(_ view: VEPreviewView) {
        engine.attachProgramView(view)
        engine.showProgramFrame(at: playheadTime)
    }

    // MARK: Playhead and zoom

    func stepFrames(_ count: Int) {
        let target = CMTimeAdd(playheadTime, CMTimeMultiply(frameDuration, multiplier: Int32(count)))
        playheadTime = CMTimeMaximum(.zero, target)
    }

    func setPlayhead(seconds: Double) {
        playheadTime = frameTime(seconds)
    }

    func zoom(by factor: Double, anchorX: CGFloat = 0) {
        var model = timelineModel
        model.zoom(by: factor, anchorX: anchorX)
        pixelsPerSecond = model.pixelsPerSecond
        scrollX = model.scrollX
    }

    func zoomIn() { zoom(by: 1.5, anchorX: timelineModel.x(forTime: playheadTime.secondsOrZero)) }
    func zoomOut() { zoom(by: 1 / 1.5, anchorX: timelineModel.x(forTime: playheadTime.secondsOrZero)) }

    /// Fits the whole sequence into `width` points.
    func zoomToFit(width: CGFloat) {
        let duration = max(sequence.duration.secondsOrZero, 1)
        pixelsPerSecond = min(TimelineViewModel.maxPixelsPerSecond,
                              max(TimelineViewModel.minPixelsPerSecond, Double(max(width - 40, 100)) / duration))
        scrollX = 0
    }

    // MARK: Selection

    func select(clip id: VEClipID, extend: Bool) {
        let group = timelineModel.expandingLinks([id])
        if extend {
            if selection.contains(id) {
                selection.subtract(group)
            } else {
                selection.formUnion(group)
            }
        } else {
            selection = group
        }
        focusArea = .timeline
    }

    func selectAll() {
        selection = Set(clips.keys)
        focusArea = .timeline
    }

    // MARK: Timeline edits

    /// Cmd+K: splits the selected clips at the playhead, or every clip under it on unlocked
    /// tracks when nothing selected spans the playhead.
    func splitAtPlayhead() {
        let t = playheadTime
        let spanning = selectedClips.filter { $0.timelineStart < t && t < $0.timelineEnd }
        let ids = spanning.map { NSNumber(value: $0.clipID) }
        report(engine.splitClips(ids, at: t))
    }

    func deleteSelection(ripple: Bool) {
        if focusArea == .mediaBin, selection.isEmpty, let asset = selectedAssetID {
            removeAsset(asset)
            return
        }
        if selection.isEmpty, let transition = selectedTransitionID {
            if report(engine.removeTransition(transition)) {
                selectedTransitionID = nil
            }
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection.map { NSNumber(value: $0) }
        if report(ripple ? engine.rippleDeleteClips(ids) : engine.removeClips(ids)) {
            selection = []
        }
    }

    /// Adds a one-second cross dissolve on the cut nearest the playhead on the target video
    /// track (or the selected clip's track).
    func addCrossDissolveAtPlayhead() {
        let trackID = selectedClips.first?.trackID ?? targetVideoTrackID
        let onTrack = clips.values.filter { $0.trackID == trackID }.sorted { $0.timelineStart < $1.timelineStart }
        let playhead = playheadTime.secondsOrZero
        var best: (VEClipInfo, VEClipInfo)?
        var bestDistance = Double.infinity
        for (from, to) in zip(onTrack, onTrack.dropFirst()) where from.timelineEnd == to.timelineStart {
            let distance = abs(from.timelineEnd.secondsOrZero - playhead)
            if distance < bestDistance {
                best = (from, to)
                bestDistance = distance
            }
        }
        guard let (from, to) = best else {
            statusMessage = "No cut between two adjacent clips on this track."
            return
        }
        let duration = CMTimeMultiply(frameDuration, multiplier: Int32(max(1, Timecode.framesPerSecond(frameDuration))))
        let result = engine.addTransition(fromClip: from.clipID, toClip: to.clipID, duration: duration)
        if report(result), let id = result.createdIDs.first?.int64Value {
            selectedTransitionID = id
            selection = []
        }
    }

    func linkOrUnlinkSelection() {
        let chosen = selectedClips
        if let clip = chosen.first, chosen.allSatisfy({ $0.linkedClipID != 0 }) {
            report(engine.unlinkClip(clip.clipID))
        } else if chosen.count == 2 {
            report(engine.linkClip(chosen[0].clipID, withClip: chosen[1].clipID))
        } else {
            statusMessage = "Select two unlinked clips on different tracks to link them."
        }
    }

    /// The audio track paired with a video track (A<n> for V<n>), else the target audio track.
    func matchingAudioTrack(forVideo videoTrackID: VETrackID) -> VETrackID {
        guard let video = track(videoTrackID) else { return targetAudioTrackID }
        let audio = audioTracks
        return audio.first { $0.index == video.index }?.trackID ?? targetAudioTrackID
    }

    func matchingVideoTrack(forAudio audioTrackID: VETrackID) -> VETrackID {
        guard let audio = track(audioTrackID) else { return targetVideoTrackID }
        return videoTracks.first { $0.index == audio.index }?.trackID ?? targetVideoTrackID
    }

    /// Places an asset at `time` with its picture on `videoTrack` and its sound on `audioTrack`.
    @discardableResult
    func place(asset id: VEAssetID, at time: CMTime, videoTrack: VETrackID, audioTrack: VETrackID,
               sourceIn: CMTime = .invalid, sourceOut: CMTime = .invalid, overwrite: Bool) -> Bool {
        let result = overwrite
            ? engine.overwriteAsset(id, at: time, videoTrack: videoTrack, audioTrack: audioTrack,
                                    sourceIn: sourceIn, sourceOut: sourceOut)
            : engine.insertAsset(id, at: time, videoTrack: videoTrack, audioTrack: audioTrack,
                                 sourceIn: sourceIn, sourceOut: sourceOut)
        if report(result) {
            selection = Set(result.createdIDs.map(\.int64Value))
            focusArea = .timeline
            return true
        }
        return false
    }

    /// Places an asset dropped on the timeline on the row `trackID` (its partner goes on the
    /// matching track of the other kind).
    @discardableResult
    func dropAsset(_ id: VEAssetID, onTrack trackID: VETrackID, at seconds: Double, overwrite: Bool) -> Bool {
        guard let dropped = track(trackID) else { return false }
        let video = dropped.kind == .video ? trackID : matchingVideoTrack(forAudio: trackID)
        let audio = dropped.kind == .audio ? trackID : matchingAudioTrack(forVideo: trackID)
        return place(asset: id, at: frameTime(seconds), videoTrack: video, audioTrack: audio, overwrite: overwrite)
    }

    // MARK: Source monitor

    func showInSourceMonitor(_ id: VEAssetID) {
        guard asset(id) != nil else { return }
        if source.assetID != id {
            source = SourceMonitorState(assetID: id)
        }
        selectedAssetID = id
    }

    /// Length of the source monitor's asset (stills: the default still duration).
    var sourceDuration: CMTime {
        guard let id = source.assetID, let info = asset(id) else { return .zero }
        return info.isStill ? CMTime(value: 5, timescale: 1) : info.duration
    }

    func markSourceIn() {
        guard source.assetID != nil else { return }
        source.inPoint = source.time
        if let out = source.outPoint, out <= source.time { source.outPoint = nil }
    }

    func markSourceOut() {
        guard source.assetID != nil else { return }
        source.outPoint = source.time
        if let inPoint = source.inPoint, inPoint >= source.time { source.inPoint = nil }
    }

    /// Insert / Overwrite from the source monitor at the playhead on the target tracks.
    func placeSource(overwrite: Bool) {
        guard let id = source.assetID, let info = asset(id) else {
            statusMessage = "Open a clip in the source monitor first (double-click it in the media bin)."
            return
        }
        let videoTrack = info.hasVideo ? targetVideoTrackID : 0
        let audioTrack = info.hasAudio ? (info.hasVideo ? matchingAudioTrack(forVideo: targetVideoTrackID)
                                                        : targetAudioTrackID) : 0
        place(asset: id, at: playheadTime, videoTrack: videoTrack, audioTrack: audioTrack,
              sourceIn: source.inPoint ?? .invalid, sourceOut: source.outPoint ?? .invalid, overwrite: overwrite)
    }

    // MARK: Media

    /// Imports files (probing happens off the main thread).
    func importMedia(_ urls: [URL], completion: (([VEAssetInfo]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        isImporting = true
        engine.importMedia(at: urls) { [weak self] imported, errors in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isImporting = false
                if !errors.isEmpty {
                    self.statusMessage = errors.map(\.localizedDescription).joined(separator: "\n")
                }
                if let first = imported.first {
                    self.selectedAssetID = first.assetID
                    self.focusArea = .mediaBin
                }
                completion?(imported)
            }
        }
    }

    func removeAsset(_ id: VEAssetID) {
        if report(engine.removeAsset(id)), selectedAssetID == id {
            selectedAssetID = nil
        }
    }

    // MARK: Documents

    /// Discards the open project (callers confirm unsaved changes first).
    func newProject() {
        cancelActiveGesture?()
        engine.newProject(withName: "Untitled")
        resetUIState()
    }

    func open(url: URL) throws {
        cancelActiveGesture?()
        try engine.openProject(at: url)
        resetUIState()
        let missing = engine.missingAssetIDs.count
        if missing > 0 {
            statusMessage = missing == 1 ? "1 media file could not be found." : "\(missing) media files could not be found."
        }
    }

    func save(to url: URL) throws {
        cancelActiveGesture?()
        try engine.saveProject(to: url)
        refreshModel()
    }

    private func resetUIState() {
        thumbnails.removeAll()
        waveforms.removeAll()
        selection = []
        selectedAssetID = nil
        source = SourceMonitorState()
        playheadTime = .zero
        scrollX = 0
        scrollY = 0
        statusMessage = nil
        refreshAssets()
        refreshModel()
    }
}
