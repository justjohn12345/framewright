import AppKit
import Combine
import CoreMedia
import Foundation
import FramewrightEngine

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
    /// The inspector's editing logic (parameters, nudges, sliders, resets, messages).
    private(set) lazy var inspector = InspectorModel(store: self)
    /// Where media received from Photos is kept (the project's Media folder).
    let mediaFolder = ImportedMediaFolder()
    /// Media arriving from Photos (file promise drops, Import from Photos…), shown in the bin.
    private(set) lazy var incoming = IncomingMedia(store: self)
    /// File > Import from Photos… (the system photo picker).
    private(set) lazy var photosPicker = PhotosImportPicker(store: self)
    /// The Editing preferences (Settings > Editing), observed: a change re-renders every view
    /// observing the store (durations re-format at once, without a model change).
    let preferences = EditingPreferencesModel()
    /// Where the Editing preferences are read from (tests use their own suite).
    var defaults: UserDefaults {
        get { preferences.defaults }
        set { preferences.defaults = newValue }
    }

    var editingPreferences: EditingPreferences { preferences.current }
    /// The window layout (panels, the inspector's tab, split positions). Persisted in the app's
    /// defaults for the app's store; a store made for tests keeps it in memory.
    let layout: WindowLayoutModel
    /// The program monitor on a second display (View > Program Monitor on Second Display), over
    /// the system's screens (tests replace it with one over their own screen list).
    lazy var outputDisplay = OutputDisplayController(store: self, screens: SystemScreens())

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
    @Published var selection: Set<VEClipID> = [] {
        didSet {
            // The Ken Burns helper edits one selected clip: deselecting it, or adding another clip to
            // the selection (the inspector then hides the helper's controls), closes it.
            if let kenBurns, selection != [kenBurns.clipID] { self.kenBurns = nil }
        }
    }
    @Published var selectedAssetID: VEAssetID?
    @Published var selectedTransitionID: VETransitionID?
    @Published private(set) var source = SourceMonitorState()
    @Published var targetVideoTrackID: VETrackID = 0
    @Published var targetAudioTrackID: VETrackID = 0
    @Published var focusArea: FocusArea = .timeline
    /// Empty tracks whose rows the user collapsed (a track with clips always shows full height).
    @Published private(set) var collapsedTrackIDs: Set<VETrackID> = []
    /// Last refused edit, edit note or import problem, shown in the transport bar.
    @Published var statusMessage: String?
    /// The snap line shown while dragging (seconds), or nil.
    @Published var snapIndicator: Double?
    /// A video dissolve waiting for the user to decide about the linked audio crossfade
    /// (Editing preference "Ask each time"); shown as a confirmation dialog.
    @Published var pendingLinkedTransition: PendingTransition?
    /// Clips the Speed/Duration sheet edits (nil: the sheet is closed).
    @Published var speedSheetClipIDs: [VEClipID]?
    /// The Export sheet's model while the sheet is open (File > Export…).
    @Published var exportModel: ExportModel?
    /// An export is running (the engine's `isExporting`, republished).
    @Published private(set) var isExporting = false
    /// The Ken Burns helper drawn on the program monitor while it edits a clip (nil otherwise).
    @Published private(set) var kenBurns: KenBurnsModel? {
        didSet {
            guard kenBurns !== oldValue else { return }
            // The timeline marks the open helper's range; closing it (Apply, Cancel, selection...)
            // hides the band.
            kenBurnsBandForwarding = kenBurns?.$bandRange.sink { [weak band = kenBurnsBand] range in
                // Published on the main actor, where the model changes.
                MainActor.assumeIsolated { band?.show(range) }
            }
            if kenBurns == nil { kenBurnsBand.show(nil) }
        }
    }
    /// The Ken Burns range the timeline highlights while the helper is open.
    let kenBurnsBand = KenBurnsTimelineBand()
    private var kenBurnsBandForwarding: AnyCancellable?
    /// Asks the inspector to focus a field (double-clicking a transition focuses its duration).
    @Published private(set) var inspectorFocusRequest: InspectorFocusRequest?
    /// The coalescing group of the inspector's keyboard-nudge burst, while one is open. Unlike a
    /// drag it does not block other commands: another edit simply commits the burst first.
    var nudgeGroup: String?

    /// Width of the timeline's track area, for Zoom to Fit (updated by the timeline).
    var timelineViewportWidth: CGFloat = 800

    /// Cancels the timeline gesture in progress (set by the timeline while dragging).
    var cancelActiveGesture: (() -> Void)?

    /// The editor window (set by `ContentView`). Keyboard shortcuts are taken only from it, and
    /// clicks in the timeline, monitors and bin take keyboard focus back from its text fields. The
    /// program output is available once its display is known (`OutputDisplayController`).
    weak var editorWindow: NSWindow? {
        didSet {
            if editorWindow !== oldValue { outputDisplay.screensChanged() }
        }
    }

    /// A gesture is in progress: a timeline drag (move, trim, marquee, playhead, transition or
    /// fade handle, gain line) or an edit group such as an inspector slider drag. Edit commands
    /// (Delete, Split, Link, Insert...) from keys and menus are ignored meanwhile, so they never
    /// interleave with the gesture's own coalesced edits (the engine would commit the gesture
    /// first; see VEEngine.h). An inspector nudge burst is not a gesture: the next command
    /// commits it as its own undo step.
    var isGestureActive: Bool {
        guard cancelActiveGesture == nil else { return true }
        guard let key = engine.coalescingKey else { return false }
        return key != nudgeGroup
    }

    /// Number of times the timeline's content model was rebuilt (once per model change;
    /// diagnostics and tests).
    private(set) var timelineBuildCount = 0
    private var cachedTimeline: (changeCount: UInt64, collapsed: Set<VETrackID>, model: TimelineViewModel)?
    private var observers: [NSObjectProtocol] = []
    private var preferencesForwarding: AnyCancellable?
    /// Tells the engine whether the source monitor is on screen (it drops the source controller's
    /// stopped lookahead while hidden).
    private var sourceVisibilityForwarding: AnyCancellable?

    /// The app's store: a new engine with the default cache directory, the layout persisted in the
    /// standard defaults.
    convenience init() {
        self.init(engine: VEEngine(), persistentLayout: true)
    }

    /// `persistentLayout`: keep the window layout in the standard defaults (the app); otherwise it
    /// lives in memory only (tests, which run inside the app's process, must not change the app's
    /// saved layout).
    init(engine: VEEngine, persistentLayout: Bool = false) {
        self.engine = engine
        layout = WindowLayoutModel(defaults: persistentLayout ? .standard : nil)
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
        observe(.VEEngineExportDidFinish) { store, _ in store.exportStateChanged() }
        observe(.VEEngineMemoryPressure) { store, note in
            let critical = (note.userInfo?[VEEngineCriticalKey] as? NSNumber)?.boolValue ?? false
            store.thumbnails.handleMemoryPressure(critical: critical)
            store.waveforms.handleMemoryPressure(critical: critical)
            store.kenBurns?.picture?.handleMemoryPressure()
        }
        preferencesForwarding = preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // The open Ken Burns helper shows durations in the chosen format too (the change is
            // read once it has been made).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let kenBurns = self.kenBurns else { return }
                    kenBurns.durationDisplay = self.editingPreferences.durationDisplay
                }
            }
        }
        // Every path that shows or hides the monitor (the menu, a double-click in the bin, Reset
        // Window Layout, the saved layout at launch) goes through `layout.showsSourceMonitor`.
        sourceVisibilityForwarding = layout.$showsSourceMonitor.removeDuplicates().sink { [weak engine] visible in
            MainActor.assumeIsolated { engine?.sourceMonitorVisible = visible }
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
        if let kenBurns {
            if let clip = byID[kenBurns.clipID] {
                kenBurns.update(clip: clip, previous: adjacentClip(to: clip.clipID, at: .start),
                                next: adjacentClip(to: clip.clipID, at: .end))
            } else {
                self.kenBurns = nil
            }
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

    /// Height of the timeline's rows (for sizing the timeline pane to its content).
    var timelineContentHeight: CGFloat {
        timelineContent.contentHeight
    }

    private var timelineContent: TimelineViewModel {
        if let cached = cachedTimeline, cached.changeCount == changeCount, cached.collapsed == collapsedTrackIDs {
            return cached.model
        }
        timelineBuildCount += 1
        var model = TimelineViewModel()
        model.frameSeconds = frameDuration.secondsOrZero
        let occupied = Set(clips.values.map(\.trackID))
        model.tracks = tracks.map {
            TimelineViewModel.Track(id: $0.trackID, kind: $0.kind == .video ? .video : .audio, index: $0.index,
                                    name: $0.name, muted: $0.muted, solo: $0.solo, locked: $0.locked,
                                    isEmpty: !occupied.contains($0.trackID),
                                    collapsed: collapsedTrackIDs.contains($0.trackID) && !occupied.contains($0.trackID))
        }
        model.clips = clips.values.map {
            let audio = $0.audioParams
            return TimelineViewModel.Clip(id: $0.clipID, trackID: $0.trackID, assetID: $0.assetID, name: $0.name,
                                          start: $0.timelineStart.secondsOrZero, end: $0.timelineEnd.secondsOrZero,
                                          sourceIn: $0.sourceIn.secondsOrZero, speed: $0.speed,
                                          linkedClipID: $0.linkedClipID, isStill: $0.isStill,
                                          isAudio: $0.trackKind == .audio, gainDb: audio.gainDb,
                                          fadeIn: audio.fadeInDuration.secondsOrZero,
                                          fadeOut: audio.fadeOutDuration.secondsOrZero,
                                          keyframes: Self.keyframeFrames(of: $0))
        }.sorted { $0.start < $1.start }
        model.transitions = sequence.transitions.map {
            TimelineViewModel.Transition(id: $0.transitionID, trackID: $0.trackID, start: $0.start.secondsOrZero,
                                         end: $0.end.secondsOrZero, fromClipID: $0.fromClipID, toClipID: $0.toClipID)
        }
        cachedTimeline = (changeCount, collapsedTrackIDs, model)
        return model
    }

    /// The frames (seconds) of a video clip that show a Motion keyframe, one per frame, in order;
    /// keyframes a trim cut off are left out.
    static func keyframeFrames(of clip: VEClipInfo) -> [Double] {
        guard clip.trackKind == .video, clip.hasKeyframes else { return [] }
        var frames: [CMTime] = []
        for keyframe in clip.allKeyframes where keyframe.isInsideClip {
            if !frames.contains(keyframe.frameTime) { frames.append(keyframe.frameTime) }
        }
        return frames.sorted().map(\.secondsOrZero)
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

    /// Sequence frames in `time` (rounded).
    func frames(_ time: CMTime) -> Int64 {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return 0 }
        return Int64((time.secondsOrZero / frame).rounded())
    }

    /// `frames` sequence frames as a time.
    func time(frames: Int64) -> CMTime {
        CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frames))
    }

    /// A duration in the user's preferred form (Settings > Editing).
    func durationString(frames: Int64) -> String {
        DurationFormat.string(frames: frames, frameDuration: frameDuration,
                              display: editingPreferences.durationDisplay)
    }

    /// The compact form of `durationString` (timeline labels: "1:05", "35f", "1.17s").
    func shortDurationString(frames: Int64) -> String {
        DurationFormat.shortString(frames: frames, frameDuration: frameDuration,
                                   display: editingPreferences.durationDisplay)
    }

    /// Asks the inspector to focus `field`.
    func requestInspectorFocus(_ field: InspectorFocusRequest.Field) {
        layout.inspectorTab = .inspector
        inspectorFocusRequest = InspectorFocusRequest(field: field, serial: (inspectorFocusRequest?.serial ?? 0) + 1)
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

    // MARK: Track rows

    /// Whether the track has no clips (only empty tracks collapse).
    func isTrackEmpty(_ id: VETrackID) -> Bool {
        !clips.values.contains { $0.trackID == id }
    }

    /// Collapses an empty track's row to a short strip, or expands it again. A track that gets a
    /// clip shows at full height whatever its collapse state.
    func setTrack(_ id: VETrackID, collapsed: Bool) {
        if collapsed {
            guard isTrackEmpty(id), track(id) != nil else { return }
            collapsedTrackIDs.insert(id)
        } else {
            collapsedTrackIDs.remove(id)
        }
    }

    /// Whether the track's row is shown collapsed (collapsed and still empty).
    func isTrackCollapsed(_ id: VETrackID) -> Bool {
        collapsedTrackIDs.contains(id) && isTrackEmpty(id)
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
            // A dissolve goes with its linked crossfade (they were added as one step).
            removeTransition(transition, includingLinked: true)
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection.map { NSNumber(value: $0) }
        if report(ripple ? engine.rippleDeleteClips(ids) : engine.removeClips(ids)) {
            selection = []
        }
    }

    /// Removes a transition (Delete in the timeline, the inspector's Delete button, whatever panel
    /// has the focus) and, with `includingLinked`, its linked transition (the crossfade under a
    /// dissolve, or the other way round) in the same undo step; Option-Delete and "Delete This
    /// Transition Only" pass false. Ignored during a gesture; a refusal is reported.
    @discardableResult
    func removeTransition(_ id: VETransitionID, includingLinked: Bool) -> Bool {
        guard !isGestureActive else { return false }
        guard report(engine.removeTransition(id, includingLinked: includingLinked)) else { return false }
        if let selected = selectedTransitionID, engine.transitionInfo(selected) == nil { selectedTransitionID = nil }
        return true
    }

    /// Option-Delete (Clip > Delete Transition Only): removes the selected transition without its
    /// linked one. Ignored during a gesture.
    func deleteSelectedTransitionOnly() {
        guard !isGestureActive, selection.isEmpty, let transition = selectedTransitionID else { return }
        removeTransition(transition, includingLinked: false)
    }

    /// The transition linked to `id` (see `VEEngine.linkedTransition(forTransition:)`), or nil.
    func linkedTransition(of id: VETransitionID) -> VETransitionID? {
        let linked = engine.linkedTransition(forTransition: id)
        return linked == 0 ? nil : linked
    }

    /// Whether a duration change of a transition also changes its linked transition (the
    /// Transition inspector's checkbox; remembered in the Editing preferences, on by default).
    var resizesLinkedTransitions: Bool {
        get { editingPreferences.resizeLinkedTransitions }
        set { defaults.set(newValue, forKey: EditingPreferences.resizeLinkedTransitionsKey) }
    }

    /// Adds a transition of `kind` (Shift+Cmd+D: cross dissolve; Option+Shift+Cmd+D: audio
    /// crossfade) on the selected clips' track of that kind, else the target track, at the cut
    /// `nearestCut` picks, with the default duration (Settings > Editing). Refusals are reported.
    func addTransitionAtPlayhead(_ kind: TransitionKind) {
        guard !isGestureActive else { return }
        let selectedTrack = selectedClips.first { ($0.trackKind == .video) == (kind.trackKind == .video) }?.trackID
        let trackID = selectedTrack ?? (kind.trackKind == .video ? targetVideoTrackID : targetAudioTrackID)
        let name = track(trackID)?.name ?? ""
        guard hasCut(onTrack: trackID) else {
            statusMessage = "No cut between two adjacent clips on track \(name)."
            return
        }
        guard let (from, to) = nearestCut(onTrack: trackID, toSeconds: playheadTime.secondsOrZero) else {
            statusMessage = "Move the playhead near a cut: none on track \(name) is within "
                + "\(Int(Self.cutSearchSeconds)) seconds of it."
            return
        }
        addTransition(kind, from: from, to: to)
    }

    /// How far from the playhead (seconds) Add Cross Dissolve / Add Audio Crossfade look for a
    /// cut when the playhead is not on a clip that meets another.
    static let cutSearchSeconds = 2.0

    /// The adjacent clips meeting at a cut on `trackID`, in timeline order.
    private func cuts(onTrack trackID: VETrackID) -> [(from: VEClipInfo, to: VEClipInfo)] {
        let onTrack = clips.values.filter { $0.trackID == trackID }.sorted { $0.timelineStart < $1.timelineStart }
        return zip(onTrack, onTrack.dropFirst()).filter { pair in pair.0.timelineEnd == pair.1.timelineStart }
            .map { pair in (from: pair.0, to: pair.1) }
    }

    private func hasCut(onTrack trackID: VETrackID) -> Bool {
        !cuts(onTrack: trackID).isEmpty
    }

    /// The cut on `trackID` a transition added at the playhead (`seconds`) goes on: the nearer
    /// edge of the clip under the playhead that meets another clip; otherwise the nearest cut
    /// within `cutSearchSeconds`; nil when there is none that close.
    func nearestCut(onTrack trackID: VETrackID, toSeconds seconds: Double) -> (VEClipID, VEClipID)? {
        let all = cuts(onTrack: trackID)
        func distance(_ cut: (from: VEClipInfo, to: VEClipInfo)) -> Double {
            abs(cut.from.timelineEnd.secondsOrZero - seconds)
        }
        let under = clips.values.first {
            $0.trackID == trackID && $0.timelineStart.secondsOrZero <= seconds && seconds < $0.timelineEnd.secondsOrZero
        }
        if let under {
            let edges = all.filter { $0.from.clipID == under.clipID || $0.to.clipID == under.clipID }
            if let best = edges.min(by: { distance($0) < distance($1) }) {
                return (best.from.clipID, best.to.clipID)
            }
        }
        guard let best = all.min(by: { distance($0) < distance($1) }), distance(best) <= Self.cutSearchSeconds else {
            return nil
        }
        return (best.from.clipID, best.to.clipID)
    }

    /// Adds a transition of `kind` with the default duration on the cut between `from` and `to`,
    /// shortened to what the cut allows. A video dissolve also gets the linked audio's crossfade
    /// (one undo step, fitted to the audio's own cut) per the Editing preference: always, never,
    /// or ask (asked through `pendingLinkedTransition`, only when the audio's cut can take one).
    /// When the linked crossfade is wanted but cannot be added, the status line says why (the
    /// engine's note). Returns whether a transition was added (false while waiting for the answer).
    @discardableResult
    func addTransition(_ kind: TransitionKind, from: VEClipID, to: VEClipID, frames: Int64? = nil) -> Bool {
        guard !isGestureActive else { return false }
        let length = frames ?? editingPreferences.transitionFrames(frameDuration: frameDuration)
        var includeLinked = false
        if kind == .crossDissolve {
            switch editingPreferences.linkedCrossfade {
            case .always: includeLinked = true
            case .never: includeLinked = false
            case .ask:
                if linkedCutAcceptsTransition(from: from, to: to) {
                    pendingLinkedTransition = PendingTransition(kind: kind, fromClipID: from, toClipID: to,
                                                                frames: length)
                    return false
                }
                // Nothing to ask: the engine adds the dissolve alone and its note says why.
                includeLinked = true
            }
        }
        return commitTransition(kind, from: from, to: to, frames: length, includeLinked: includeLinked)
    }

    /// Answers the pending "also add the audio crossfade?" question.
    func resolvePendingTransition(includeLinked: Bool?) {
        guard let pending = pendingLinkedTransition else { return }
        pendingLinkedTransition = nil
        guard let includeLinked else { return } // cancelled
        commitTransition(pending.kind, from: pending.fromClipID, to: pending.toClipID, frames: pending.frames,
                         includeLinked: includeLinked)
    }

    /// Whether the linked partners of `from` and `to` meet at a cut that can take a transition.
    func linkedCutAcceptsTransition(from: VEClipID, to: VEClipID) -> Bool {
        guard let fromClip = clips[from], let toClip = clips[to], fromClip.linkedClipID != 0,
              toClip.linkedClipID != 0 else { return false }
        return engine.transitionLimit(fromClip: fromClip.linkedClipID, toClip: toClip.linkedClipID).maximumFrames > 0
    }

    @discardableResult
    private func commitTransition(_ kind: TransitionKind, from: VEClipID, to: VEClipID, frames: Int64,
                                  includeLinked: Bool) -> Bool {
        guard !isGestureActive else { return false }
        var options: VETransitionOptions = [.fitToCut]
        if includeLinked { options.insert(.includeLinked) }
        let result = engine.addTransition(fromClip: from, toClip: to, duration: time(frames: frames), options: options)
        if report(result), let id = result.createdIDs.first?.int64Value {
            selection = []
            selectedTransitionID = id
            focusArea = .timeline
            return true
        }
        return false
    }

    // MARK: Parameters from keys and menus

    /// `]` / `[` (Shift: ±10 dB): changes the gain of the selected audio clips; a burst of
    /// presses is one undo step.
    func nudgeGain(_ steps: Double) {
        guard !isGestureActive else { return }
        guard inspector.isAvailable(.gain) else {
            statusMessage = "Select an audio clip to change its gain."
            return
        }
        inspector.nudge(.gain, steps: steps)
    }

    /// Edit > Reset Video/Audio Settings: back to the defaults for every selected clip of that
    /// kind (one undo step).
    func resetSettings(_ section: InspectorSection) {
        guard !isGestureActive else { return }
        inspector.reset(section)
    }

    /// Clip > Transition Duration…: focuses the selected transition's duration in the inspector.
    func editTransitionDuration() {
        guard !isGestureActive, selectedTransitionID != nil else { return }
        selection = []
        requestInspectorFocus(.transitionDuration)
    }

    // MARK: Motion keyframes

    /// The clip Add Motion Keyframe works on: `id` when it is a video clip, else the single selected
    /// video clip (a linked pair counts as its video clip); nil otherwise.
    func motionKeyframeClip(_ id: VEClipID? = nil) -> VEClipInfo? {
        if let id {
            return clips[id].flatMap { $0.trackKind == .video ? $0 : nil }
        }
        let video = selectedClips.filter { $0.trackKind == .video }
        return video.count == 1 ? video[0] : nil
    }

    /// Whether every Motion parameter of `clip` has a keyframe on the frame under the playhead (Add
    /// Motion Keyframe then removes them).
    func hasAllMotionKeyframesAtPlayhead(_ clip: VEClipInfo, at time: CMTime? = nil) -> Bool {
        let time = time ?? playheadTime
        return ([.positionX, .positionY, .scale, .rotation, .opacity] as [VEMotionParameter]).allSatisfy {
            clip.keyframe(for: $0, at: time) != nil
        }
    }

    /// Clip > Add Motion Keyframe with the playhead at `time`: "Remove Motion Keyframes" when all
    /// five are on that frame; enabled only for a single selected video clip under the playhead.
    func motionKeyframeMenuState(at time: CMTime) -> (title: String, enabled: Bool) {
        guard let clip = motionKeyframeClip(), clip.timelineStart <= time, time < clip.timelineEnd else {
            return ("Add Motion Keyframe  ⌃K", false)
        }
        return (hasAllMotionKeyframesAtPlayhead(clip, at: time) ? "Remove Motion Keyframes  ⌃K"
            : "Add Motion Keyframe  ⌃K", true)
    }

    /// Clip > Add Motion Keyframe (Control-K), also in the timeline's context menu: on the frame under
    /// the playhead, adds keyframes to the Motion parameters of the clip that have none there (the
    /// picture does not change), or, when all five have one, removes them. One undo step; the status
    /// line says "Keyframes added on N parameters" or "Keyframes removed", or why nothing happened.
    func toggleMotionKeyframes(clip id: VEClipID? = nil) {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return
        }
        guard let clip = motionKeyframeClip(id) else {
            statusMessage = "Select a single video clip to add Motion keyframes."
            return
        }
        inspector.endNudgeBurst()
        report(engine.toggleMotionKeyframes(clip: clip.clipID, at: playheadTime))
    }

    // MARK: Neighbours

    /// The clip on the same track touching `id` at `edge`: the previous clip ending exactly where it
    /// starts (`.start`) or the next one starting exactly where it ends (`.end`); nil for a gap.
    func adjacentClip(to id: VEClipID, at edge: VEClipEdge) -> VEClipInfo? {
        let other = engine.adjacentClip(of: id, at: edge)
        return other != 0 ? clips[other] : nil
    }

    // MARK: Ken Burns

    /// The inspector's Ken Burns… button: shows the start and end rectangles of `clip` on the
    /// program monitor. A clip with a move (position or scale keyframes on two of its frames) opens
    /// on that move ("Existing move": its range, its framing at the range's ends, its smoothing), so
    /// Apply edits it in place; otherwise the range is the whole clip and the rectangles show its
    /// position and scale at its first and last frames, or a gentle push in when it has none.
    /// Nothing changes until `applyKenBurns()`.
    func beginKenBurns(clip id: VEClipID) {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return
        }
        guard let clip = clips[id], let info = asset(clip.assetID) else { return }
        if kenBurns?.clipID == id {
            return // already open on this clip: keep its rectangles and range
        }
        var reason = ""
        let picture = KenBurnsPictureLoader(assetID: info.assetID, engine: engine)
        guard let model = KenBurnsModel(clip: clip, asset: info, sequence: sequence, playhead: playheadTime,
                                        durationDisplay: editingPreferences.durationDisplay, picture: picture,
                                        previous: adjacentClip(to: id, at: .start),
                                        next: adjacentClip(to: id, at: .end), reason: &reason) else {
            statusMessage = reason
            return
        }
        if selection != [id] { selection = [id] }
        engine.pause()
        kenBurns = model
    }

    /// Applies the Ken Burns rectangles as position and scale keyframes on the first and last frames
    /// of the helper's range (one undo step) and closes the helper. A Start, End or Duration still
    /// being typed is taken first. Returns whether it was applied (a refusal is reported and the
    /// helper stays).
    @discardableResult
    func applyKenBurns() -> Bool {
        guard let model = kenBurns else { return false }
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return false
        }
        guard model.commitFields() else {
            statusMessage = model.rangeNote
            return false
        }
        if let problem = model.rangeProblem {
            statusMessage = problem
            return false
        }
        let result = engine.applyKenBurns(clip: model.clipID, start: model.startFraming, end: model.endFraming,
                                          interpolation: model.interpolation, from: model.rangeStart,
                                          duration: model.rangeDuration)
        guard report(result) else { return false }
        kenBurns = nil
        return true
    }

    /// Closes the Ken Burns helper without changing anything.
    func cancelKenBurns() {
        kenBurns = nil
    }

    // MARK: Speed

    /// Cmd+R: opens the Speed/Duration sheet for the selected clips (not stills).
    func showSpeedSheet() {
        guard !isGestureActive else { return }
        let chosen = selectedClips.filter { !$0.isStill }
        guard !chosen.isEmpty else {
            statusMessage = selection.isEmpty ? "Select the clips whose speed to change."
                : "Still images have no playback speed; trim them to change their duration."
            return
        }
        speedSheetClipIDs = chosen.map(\.clipID)
    }

    /// File > Export…: opens the Export sheet (not during a gesture).
    func showExportSheet() {
        guard !isGestureActive else {
            statusMessage = "Finish the current drag first."
            return
        }
        if exportModel == nil {
            exportModel = ExportModel(store: self)
        }
    }

    /// Re-reads whether an export runs (after one starts or ends).
    func exportStateChanged() {
        isExporting = engine.isExporting
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

    /// Opens an asset in the source monitor (a double-click in the bin), showing the monitor if it
    /// was hidden.
    func showInSourceMonitor(_ id: VEAssetID) {
        guard asset(id) != nil else { return }
        layout.showsSourceMonitor = true
        if source.assetID != id {
            source = SourceMonitorState(assetID: id)
            sourcePlayhead.reset()
            engine.sourceMonitorShowAsset(id, at: .zero)
        }
        selectedAssetID = id
        focusArea = .sourceMonitor
    }

    /// View > Show Source Monitor. Hiding it pauses the source playback and gives the transport
    /// keys back to the program; the asset and its marks stay (showing it again shows them).
    func setSourceMonitorVisible(_ visible: Bool) {
        guard visible != layout.showsSourceMonitor else { return }
        if !visible {
            engine.sourceMonitorPause()
            if focusArea == .sourceMonitor { focusArea = .timeline }
        }
        layout.showsSourceMonitor = visible
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

    /// Imports dropped files and places them on the timeline where they were dropped (one after
    /// another, in drop order) once they are imported, unless the timeline changed meanwhile (see
    /// `place(imported:from:at:timelineChanged:emptyRangeOnly:)`).
    func importAndPlace(_ urls: [URL], at placement: IncomingMedia.Placement) {
        guard !urls.isEmpty else { return }
        importMedia(urls) { [weak self] imported in
            guard let self else { return }
            // The import itself is one change (ImportAssets); anything else changed the timeline.
            let own: UInt64 = urls.contains { url in imported.contains { Self.samePath($0.path, url.path) } } ? 1 : 0
            let changed = self.engine.changeCount != placement.changeCount + own
            self.place(imported: imported, from: urls, at: placement, timelineChanged: changed, emptyRangeOnly: false)
        }
    }

    /// Places the assets imported from `files` on the timeline at `placement`: the first at the drop
    /// point on the drop row (its partner on the matching track), each next one where the previous
    /// ends; overwrite, or insert when Command was held. The media stays in the bin, with a message
    /// saying why, when a drag, a nudge burst or another gesture is in progress, when
    /// `timelineChanged` (the user edited since the drop: placing it now could overwrite those
    /// edits), when the drop's track no longer exists, or when the engine refuses the placement.
    /// With `emptyRangeOnly` (media that arrived after a wait, like Photos items) a drop point that
    /// is not empty takes the media as an insert, so nothing there is overwritten.
    func place(imported assets: [VEAssetInfo], from files: [URL], at placement: IncomingMedia.Placement,
               timelineChanged: Bool, emptyRangeOnly: Bool) {
        let ordered = files.compactMap { url in assets.first { Self.samePath($0.path, url.path) } }
        guard !ordered.isEmpty else { return }
        let what = ordered.count == 1 ? "“\(ordered[0].name)” is" : "The \(ordered.count) dropped items are"
        guard !isGestureActive, engine.coalescingKey == nil else {
            statusMessage = "\(what) in the media bin: a drag or a nudge was in progress when it arrived."
            return
        }
        guard !timelineChanged else {
            statusMessage = "\(what) in the media bin: the timeline changed after the drop, so it was not placed "
                + "(drag it to the timeline)."
            return
        }
        guard track(placement.trackID) != nil else {
            statusMessage = "\(what) in the media bin: the track it was dropped on no longer exists."
            return
        }
        var insert = placement.insert
        if emptyRangeOnly, !insert, !isRangeEmpty(for: ordered, on: placement.trackID, from: placement.seconds) {
            insert = true
        }
        var seconds = placement.seconds
        for asset in ordered {
            guard dropAsset(asset.assetID, onTrack: placement.trackID, at: seconds, overwrite: !insert) else {
                let reason = statusMessage ?? "it could not be placed"
                statusMessage = "“\(asset.name)” is in the media bin: \(reason)"
                return
            }
            seconds = selection.compactMap { clips[$0]?.timelineEnd.secondsOrZero }.max() ?? seconds
        }
        if insert, !placement.insert {
            statusMessage = "Inserted where it was dropped: the timeline there was no longer empty."
        }
    }

    /// Whether the time `assets` take, placed one after another from `seconds` on the row
    /// `trackID` and its partner row, holds no clip.
    private func isRangeEmpty(for assets: [VEAssetInfo], on trackID: VETrackID, from seconds: Double) -> Bool {
        guard let dropped = track(trackID) else { return false }
        let video = dropped.kind == .video ? trackID : matchingVideoTrack(forAudio: trackID)
        let audio = dropped.kind == .audio ? trackID : matchingAudioTrack(forVideo: trackID)
        let length = assets.reduce(0.0) { total, asset in
            total + (asset.isStill ? Self.stillSeconds : max(asset.duration.secondsOrZero, frameDuration.secondsOrZero))
        }
        let end = seconds + length
        let epsilon = 1e-6
        return !clips.values.contains { clip in
            (clip.trackID == video || clip.trackID == audio)
                && clip.timelineStart.secondsOrZero < end - epsilon && clip.timelineEnd.secondsOrZero > seconds + epsilon
        }
    }

    /// The length a still gets when placed (the engine's default).
    static let stillSeconds = 5.0

    /// Whether two paths name the same file (symbolic links such as /var -> /private/var resolved).
    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
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
        // Saved elsewhere (Save As): the Media folder next to the old location is not the new one's.
        mediaFolder.projectWillMove(to: url, engine: engine)
        try engine.saveProject(to: url)
        refreshModel()
    }

    private func resetUIState() {
        kenBurns = nil
        // Media still arriving belongs to the previous project (its Media folder).
        incoming.discardAll()
        mediaFolder.reset()
        thumbnails.removeAll()
        waveforms.removeAll()
        selection = []
        selectedAssetID = nil
        collapsedTrackIDs = [] // track ids restart per project
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
