import AppKit
import Combine
import CoreMedia
import Foundation
import VidEditEngine

/// Source monitor state: the asset shown and the in/out marks (on the asset's frame grid). The
/// position lives in `ProjectStore.sourcePlayhead`.
struct SourceMonitorState: Equatable {
    var assetID: VEAssetID?
    var inPoint: CMTime?
    var outPoint: CMTime?
}

/// Which panel the user worked in last (decides what Delete removes and which monitor the
/// transport keys drive).
enum FocusArea {
    case timeline
    case mediaBin
    case sourceMonitor
}

/// The app's single source of truth over the engine (`VEEngine`).
///
/// It republishes engine snapshots (sequence, tracks, clips, assets, undo state) whenever the
/// engine's model changes, and owns UI state: selection, the source monitor and track
/// targeting. State that changes at the display rate is published by separate objects so it
/// never invalidates views that do not show it: `playhead` / `sourcePlayhead` (position and
/// transport state, driven by the engine's playback notifications) and `viewport` (timeline
/// zoom and scroll). Every edit goes through the engine; a refused edit leaves a message in
/// `statusMessage`.
@MainActor
final class ProjectStore: ObservableObject {
    let engine: VEEngine
    let thumbnails: ThumbnailCache
    let waveforms: WaveformCache
    let playhead = PlayheadModel()
    let sourcePlayhead = PlayheadModel()
    let viewport = TimelineViewport()
    private(set) lazy var playbackActions: PlaybackActions = EnginePlaybackActions(store: self)

    // Engine snapshots.
    @Published private(set) var sequence: VESequenceInfo
    @Published private(set) var tracks: [VETrackInfo] = []
    @Published private(set) var clips: [VEClipID: VEClipInfo] = [:]
    @Published private(set) var assets: [VEAssetInfo] = []
    /// `assets` by id (rebuilt with `assets`).
    private(set) var assetsByID: [VEAssetID: VEAssetInfo] = [:]
    @Published private(set) var changeCount: UInt64 = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoActionName = ""
    @Published private(set) var redoActionName = ""
    @Published private(set) var isDirty = false
    @Published private(set) var projectURL: URL?
    @Published private(set) var projectName = "Untitled"
    /// True while at least one import is probing its files.
    @Published private(set) var isImporting = false
    private var importsInFlight = 0 {
        didSet { isImporting = importsInFlight > 0 }
    }

    // UI state.
    @Published var selection: Set<VEClipID> = []
    @Published var selectedAssetID: VEAssetID?
    @Published var selectedTransitionID: VETransitionID?
    @Published private(set) var source = SourceMonitorState()
    @Published var targetVideoTrackID: VETrackID = 0
    @Published var targetAudioTrackID: VETrackID = 0
    @Published var focusArea: FocusArea = .timeline
    /// Last refused edit, edit note or import problem, shown in the transport bar.
    @Published var statusMessage: String?
    /// The snap line shown while dragging (seconds), or nil.
    @Published var snapIndicator: Double?

    /// Width of the timeline's track area, for Zoom to Fit (updated by the timeline).
    var timelineViewportWidth: CGFloat = 800

    /// Cancels the timeline gesture in progress (set by the timeline while dragging).
    var cancelActiveGesture: (() -> Void)?

    /// The editor window (set by `ContentView`). Keyboard shortcuts are taken only from it, and
    /// clicks in the timeline, monitors and bin take keyboard focus back from its text fields.
    weak var editorWindow: NSWindow?

    /// A gesture is in progress: a timeline drag (move, trim, marquee, playhead) or an edit
    /// group such as an inspector slider drag. Edit commands (Delete, Split, Link, Insert...)
    /// from keys and menus are ignored meanwhile, so they never interleave with the gesture's
    /// own coalesced edits (the engine would commit the gesture first; see VEEngine.h).
    var isGestureActive: Bool {
        cancelActiveGesture != nil || engine.isCoalescing
    }

    /// Number of times the timeline's content model was rebuilt (once per model change;
    /// diagnostics and tests).
    private(set) var timelineBuildCount = 0
    private var cachedTimeline: (changeCount: UInt64, model: TimelineViewModel)?
    private var observers: [NSObjectProtocol] = []

    /// A store over a new engine with the default cache directory.
    convenience init() {
        self.init(engine: VEEngine())
    }

    init(engine: VEEngine) {
        self.engine = engine
        thumbnails = ThumbnailCache(engine: engine)
        waveforms = WaveformCache(engine: engine)
        sequence = engine.sequence
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (ProjectStore, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: engine, queue: .main) { [weak self] note in
                // Delivered on the main queue.
                nonisolated(unsafe) let received = note
                MainActor.assumeIsolated {
                    if let self { handler(self, received) }
                }
            })
        }
        observe(.VEEngineModelDidChange) { store, _ in store.refreshModel() }
        observe(.VEEngineAssetsDidChange) { store, _ in store.refreshAssets() }
        observe(.VEEnginePlaybackDidChange) { store, note in
            if let status = note.userInfo?[VEEnginePlaybackStatusKey] as? VEPlaybackStatus {
                store.playhead.apply(status)
            }
        }
        observe(.VEEngineSourcePlaybackDidChange) { store, note in
            if let status = note.userInfo?[VEEnginePlaybackStatusKey] as? VEPlaybackStatus {
                store.sourcePlayhead.apply(status)
            }
        }
        observe(.VEEngineMemoryPressure) { store, note in
            let critical = (note.userInfo?[VEEngineCriticalKey] as? NSNumber)?.boolValue ?? false
            store.thumbnails.handleMemoryPressure(critical: critical)
            store.waveforms.handleMemoryPressure(critical: critical)
        }
        refreshAssets()
        refreshModel()
        playhead.apply(engine.playbackStatus)
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
        let kept = selection.filter { byID[$0] != nil }
        if kept != selection { selection = kept }
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
        let fresh = engine.allAssets
        assetsByID = Dictionary(fresh.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
        assets = fresh
        let ids = Set(assetsByID.keys)
        if let selected = selectedAssetID, !ids.contains(selected) { selectedAssetID = nil }
        if let shown = source.assetID, !ids.contains(shown) {
            source = SourceMonitorState()
            sourcePlayhead.reset()
        }
    }

    func asset(_ id: VEAssetID) -> VEAssetInfo? {
        assetsByID[id]
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

    /// The geometry model for the timeline at the current zoom, scroll and playhead. Its content
    /// (tracks, clips, transitions) is built once per model change and reused.
    var timelineModel: TimelineViewModel {
        var model = timelineContent
        model.pixelsPerSecond = viewport.pixelsPerSecond
        model.scrollX = viewport.scrollX
        model.scrollY = viewport.scrollY
        model.playhead = playhead.time.secondsOrZero
        return model
    }

    private var timelineContent: TimelineViewModel {
        if let cached = cachedTimeline, cached.changeCount == changeCount {
            return cached.model
        }
        timelineBuildCount += 1
        var model = TimelineViewModel()
        model.frameSeconds = frameDuration.secondsOrZero
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
        cachedTimeline = (changeCount, model)
        return model
    }

    /// Converts seconds to a CMTime on the sequence frame grid.
    func frameTime(_ seconds: Double) -> CMTime {
        CMTime.onFrameGrid(seconds: seconds, frameDuration: frameDuration)
    }

    // MARK: Edit helpers

    /// Reports a refused edit (or a successful edit's note); returns whether it succeeded.
    @discardableResult
    func report(_ result: VEEditResult) -> Bool {
        if result.ok {
            statusMessage = result.note.isEmpty ? nil : result.note
        } else {
            statusMessage = result.message
        }
        return result.ok
    }

    /// Cmd+Z: during a drag it only cancels the drag (the drag was never committed, so there is
    /// nothing else to undo).
    func undo() {
        if let cancel = cancelActiveGesture {
            cancel()
            return
        }
        _ = engine.undo()
    }

    func redo() {
        if let cancel = cancelActiveGesture {
            cancel()
            return
        }
        _ = engine.redo()
    }

    // MARK: Keyboard focus

    /// A click in the timeline, a monitor or the bin: a text field or other control of the
    /// editor window that holds keyboard focus gives it up (ending its editing), so Space,
    /// Delete and the other editing keys reach the editor again.
    func reclaimKeyboardFocus() {
        guard let window = editorWindow,
              !KeyboardController.shouldHandleKeys(firstResponder: window.firstResponder) else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: Monitors

    func attachProgramView(_ view: VEPreviewView) {
        engine.attachProgramView(view)
    }

    func attachSourceView(_ view: VEPreviewView) {
        engine.attachSourceView(view)
        if let id = source.assetID {
            engine.sourceMonitorShowAsset(id, at: sourcePlayhead.time)
        }
    }

    // MARK: Playhead and zoom

    /// The program playhead. Setting it seeks (while stopped the monitor shows that frame; while
    /// playing, playback continues from there).
    var playheadTime: CMTime {
        get { playhead.time }
        set {
            let time = CMTimeMaximum(.zero, newValue.isNumeric ? newValue : .zero)
            playhead.setTime(time)
            engine.seek(to: time)
        }
    }

    func stepFrames(_ count: Int) {
        engine.stepFrames(count)
        playhead.setTime(engine.currentTime)
    }

    func setPlayhead(seconds: Double) {
        playheadTime = frameTime(seconds)
    }

    /// Ruler drag (or dragging the playhead in the track area): shows frames as fast as they
    /// decode, silently; `endScrub()` on release. The timeline takes the focus (the transport
    /// keys then drive the program monitor).
    func scrub(toSeconds seconds: Double) {
        if focusArea != .timeline { focusArea = .timeline }
        reclaimKeyboardFocus()
        let time = frameTime(seconds)
        playhead.setTime(time)
        engine.scrub(to: time)
    }

    func endScrub() {
        engine.endScrub()
        playhead.setTime(engine.currentTime)
    }

    var pixelsPerSecond: Double {
        get { viewport.pixelsPerSecond }
        set { viewport.pixelsPerSecond = newValue }
    }

    var scrollX: CGFloat {
        get { viewport.scrollX }
        set { viewport.scrollX = newValue }
    }

    var scrollY: CGFloat {
        get { viewport.scrollY }
        set { viewport.scrollY = newValue }
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
    /// tracks when nothing selected spans the playhead. `breakingTransitions` removes a
    /// transition around the playhead instead of refusing.
    func splitAtPlayhead(breakingTransitions: Bool = false) {
        guard !isGestureActive else { return }
        let t = playheadTime
        let spanning = selectedClips.filter { $0.timelineStart < t && t < $0.timelineEnd }
        let ids = spanning.map { NSNumber(value: $0.clipID) }
        let result = engine.splitClips(ids, at: t, breakingTransitions: breakingTransitions)
        if !result.ok, result.errorCode == .insideTransition {
            statusMessage = "The playhead is inside a transition. "
                + "Use Split at Playhead, Removing Transitions (⌥⌘K) to split it anyway."
            return
        }
        report(result)
    }

    /// Whether Delete has something to remove in the focused panel.
    var canDelete: Bool {
        switch focusArea {
        case .mediaBin: return selectedAssetID != nil
        case .timeline: return !selection.isEmpty || selectedTransitionID != nil
        case .sourceMonitor: return false
        }
    }

    /// Delete / Shift+Delete, for the focused panel: in the media bin they remove the selected
    /// asset (refused while clips use it), in the timeline they remove (or ripple delete) the
    /// selected clips or transition; with the source monitor focused they do nothing. Ignored
    /// during a gesture.
    func deleteSelection(ripple: Bool) {
        guard !isGestureActive else { return }
        switch focusArea {
        case .mediaBin:
            if let asset = selectedAssetID {
                removeAsset(asset)
            }
            return
        case .sourceMonitor:
            return
        case .timeline:
            break
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
        guard !isGestureActive else { return }
        let trackID = selectedClips.first?.trackID ?? targetVideoTrackID
        let onTrack = clips.values.filter { $0.trackID == trackID }.sorted { $0.timelineStart < $1.timelineStart }
        let playheadSeconds = playheadTime.secondsOrZero
        var best: (VEClipInfo, VEClipInfo)?
        var bestDistance = Double.infinity
        for (from, to) in zip(onTrack, onTrack.dropFirst()) where from.timelineEnd == to.timelineStart {
            let distance = abs(from.timelineEnd.secondsOrZero - playheadSeconds)
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
        guard !isGestureActive else { return }
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
            sourcePlayhead.reset()
            engine.sourceMonitorShowAsset(id, at: .zero)
        }
        selectedAssetID = id
        focusArea = .sourceMonitor
    }

    /// The source monitor's frame duration: the asset's nominal one (the sequence's for stills
    /// and audio).
    var sourceFrameDuration: CMTime {
        guard let id = source.assetID, let info = asset(id), info.hasVideo, !info.isStill,
              info.frameDuration.isNumeric, info.frameDuration.seconds > 0 else { return frameDuration }
        return info.frameDuration
    }

    /// Length of the source monitor's asset (stills: the default still duration).
    var sourceDuration: CMTime {
        guard let id = source.assetID, let info = asset(id) else { return .zero }
        return info.isStill ? CMTime(value: 5, timescale: 1) : info.duration
    }

    /// The source monitor's position (on the asset's frame grid). Setting it scrubs.
    var sourceTime: CMTime {
        get { sourcePlayhead.time }
        set { scrubSource(to: newValue) }
    }

    /// Shows the source asset at `time`, snapped down to its frame grid.
    func scrubSource(to time: CMTime) {
        guard let id = source.assetID else { return }
        let snapped = engine.frameTime(forAsset: id, at: CMTimeMaximum(.zero, time))
        sourcePlayhead.setTime(snapped)
        engine.sourceMonitorShowAsset(id, at: snapped)
    }

    func markSourceIn() {
        guard let id = source.assetID else { return }
        let time = engine.frameTime(forAsset: id, at: engine.sourceMonitorTime)
        source.inPoint = time
        if let out = source.outPoint, out <= time { source.outPoint = nil }
    }

    func markSourceOut() {
        guard let id = source.assetID else { return }
        let time = engine.frameTime(forAsset: id, at: engine.sourceMonitorTime)
        source.outPoint = time
        if let inPoint = source.inPoint, inPoint >= time { source.inPoint = nil }
    }

    /// Insert / Overwrite from the source monitor at the playhead on the target tracks.
    func placeSource(overwrite: Bool) {
        guard !isGestureActive else { return }
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
        importsInFlight += 1
        engine.importMedia(at: urls) { [weak self] imported, errors in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.importsInFlight -= 1
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
        } else if !engine.loadWarnings.isEmpty {
            statusMessage = "The project was adjusted to load: " + engine.loadWarnings.joined(separator: "; ")
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
        sourcePlayhead.reset()
        playhead.apply(engine.playbackStatus)
        scrollX = 0
        scrollY = 0
        statusMessage = nil
        refreshAssets()
        refreshModel()
    }
}
