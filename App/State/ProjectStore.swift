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
    /// `assets` by id (rebuilt with `assets`; tests remove an entry to stand for media the store has
    /// not caught up with yet).
    var assetsByID: [VEAssetID: VEAssetInfo] = [:]
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
    /// The selected clips. Selecting a clip clears the span selection (`selectedSpanID`): the two
    /// are exclusive.
    @Published var selection: Set<VEClipID> = [] {
        didSet {
            if !selection.isEmpty, selectedSpanID != nil { selectedSpanID = nil }
        }
    }
    /// The selected span (an effect span on lanes 1-3 or a transition on lane 0), exclusive with the
    /// clip selection: selecting a span deselects the clips (the inspector then shows the span, and
    /// Delete removes it); selecting a clip deselects the span.
    @Published var selectedSpanID: VESpanID? {
        didSet {
            if selectedSpanID != nil, !selection.isEmpty { selection = [] }
            if selectedSpanID != oldValue {
                kenBurnsClosedSpan = nil
                kenBurnsFailedSpan = nil
            }
            // A span on collapsed lanes is shown before it is edited (review L7): its track's lanes open.
            if let id = selectedSpanID, id != oldValue { revealLanes(ofSpan: id) }
            // Selecting a Motion span opens its Ken Burns editor; anything else closes it.
            syncKenBurns()
        }
    }
    @Published var selectedAssetID: VEAssetID?
    /// The selected transition: the selected span when it is a transition (lane 0). Setting it
    /// selects that span; setting nil deselects a selected transition (an effect span stays).
    var selectedTransitionID: VETransitionID? {
        get {
            // From the model snapshot, not the engine: views read it many times per redraw (review L9).
            guard let id = selectedSpanID, spansByID[id]?.kind == .transition else { return nil }
            return id
        }
        set {
            if let newValue {
                selectedSpanID = newValue
            } else if selectedTransitionID != nil {
                selectedSpanID = nil
            }
        }
    }
    @Published private(set) var source = SourceMonitorState()
    @Published var targetVideoTrackID: VETrackID = 0
    @Published var targetAudioTrackID: VETrackID = 0
    @Published var focusArea: FocusArea = .timeline
    /// Empty tracks whose rows the user collapsed (a track with clips always shows full height).
    @Published private(set) var collapsedTrackIDs: Set<VETrackID> = []
    /// The track whose lane 0 is shown for a transition dragged over it (the row under the pointer
    /// only, so no other row moves while dragging; review M6).
    @Published private(set) var revealedTransitionTrack: VETrackID?
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
    /// The Ken Burns editor drawn on the program monitor while a Motion span is selected (nil
    /// otherwise, or after the user closed it for that span).
    @Published private(set) var kenBurns: KenBurnsModel?
    /// The Motion span whose editor the user closed (Escape, Close): it stays closed while that span
    /// stays selected, until it is reopened (Ken Burns…, a click on the span).
    private var kenBurnsClosedSpan: VESpanID?
    /// The selected Motion span the Ken Burns editor could not open for (the status line said why):
    /// not tried again on every model change, only when the selection changes or Ken Burns… asks
    /// (review L8).
    private var kenBurnsFailedSpan: VESpanID?
    /// Times the editor could not open (diagnostics and tests).
    private(set) var kenBurnsOpenFailures = 0
    /// Asks the inspector to focus a field (double-clicking a transition focuses its duration).
    @Published private(set) var inspectorFocusRequest: InspectorFocusRequest?
    /// The coalescing group of the inspector's keyboard-nudge burst, while one is open. Unlike a
    /// drag it does not block other commands: another edit simply commits the burst first.
    var nudgeGroup: String?

    /// Width of the timeline's track area, for Zoom to Fit (updated by the timeline).
    var timelineViewportWidth: CGFloat = 800
    /// Height of the timeline's track area (updated by the timeline; 0 until it is laid out).
    var timelineViewportHeight: CGFloat = 0

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

    /// Number of times the timeline's content model was rebuilt (once per change of what it draws;
    /// diagnostics and tests).
    private(set) var timelineBuildCount = 0
    private var cachedTimeline: (key: TimelineCacheKey, drawn: DrawnTimeline, model: TimelineViewModel)?
    /// What the timeline's content model is made of (compared to decide whether to rebuild it).
    private struct DrawnTimeline: Equatable {
        let frameSeconds: Double
        let tracks: [TimelineViewModel.Track]
        let clips: [TimelineViewModel.Clip]
        let spans: [TimelineViewModel.Span]
    }
    /// The spans of `clips` by id (rebuilt with them).
    private(set) var spansByID: [VESpanID: VEEffectSpan] = [:]
    /// Every span seen, with its clip, as they were the last time it was there (`dropNote`).
    private(set) var spanMemory = SpanMemory()
    /// New or Open is replacing the project (its model changes are not edits of this one).
    private var replacingProject = false
    /// What the timeline's content model depends on besides the engine's model (whose change count
    /// covers the clips, the spans and so the lanes in use).
    private struct TimelineCacheKey: Equatable {
        let changeCount: UInt64
        let collapsedTracks: Set<VETrackID>
        let collapsedLanes: Set<String>
        let revealedTransitionTrack: VETrackID?
    }
    private var observers: [NSObjectProtocol] = []
    private var preferencesForwarding: AnyCancellable?
    /// Tells the engine whether the source monitor is on screen (it drops the source controller's
    /// stopped lookahead while hidden).
    private var sourceVisibilityForwarding: AnyCancellable?
    /// Redraws the timeline (which observes the store) when a track's lanes collapse or expand.
    private var laneCollapseForwarding: AnyCancellable?

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
            // The open Ken Burns editor shows durations in the chosen format too (redrawn once the
            // change has been made).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.kenBurns?.objectWillChange.send() }
            }
        }
        // Every path that shows or hides the monitor (the menu, a double-click in the bin, Reset
        // Window Layout, the saved layout at launch) goes through `layout.showsSourceMonitor`.
        sourceVisibilityForwarding = layout.$showsSourceMonitor.removeDuplicates().sink { [weak engine] visible in
            MainActor.assumeIsolated { engine?.sourceMonitorVisible = visible }
        }
        laneCollapseForwarding = layout.$collapsedLaneTracks.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
                // After the change is stored (the sink runs before it): shorter rows keep the top shown.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.clampTimelineScroll() } }
            }
        }
        refreshAssets()
        refreshModel()
        playhead.apply(engine.playbackStatus)
        // First launch (or a layout that was fitting): the timeline gets its rows' height, stored.
        layout.adoptInitialTimelineHeight(rowsHeight: timelineContent.rowsHeightWithoutLanes)
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
        let previousTracks = tracks
        tracks = engine.allTracks
        followLaneCollapse(from: previousTracks)
        var byID: [VEClipID: VEClipInfo] = [:]
        for clip in engine.allClips {
            byID[clip.clipID] = clip
        }
        var spans: [VESpanID: VEEffectSpan] = [:]
        for clip in byID.values {
            for span in clip.spans { spans[span.spanID] = span }
        }
        spansByID = spans
        clips = byID
        spanMemory.remember(byID)
        let kept = selection.filter { byID[$0] != nil }
        if kept != selection { selection = kept }
        if let span = selectedSpanID, spans[span] == nil {
            selectedSpanID = nil
        }
        // The editor re-reads its span and framings on every model change (an edit of an earlier
        // span, an undo, a trim move what it shows).
        syncKenBurns()
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
        // Not while a drag previews its edits (the view would slide under the pointer); the drag's
        // end is a model change too.
        if !isGestureActive { clampTimelineScroll() }
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

    /// Height of the timeline's rows with their lanes (what a double-click on the divider fits).
    var timelineContentHeight: CGFloat {
        timelineContent.contentHeight
    }

    /// A double-click on the divider above the timeline: fits it once to the rows it shows now, in a
    /// window content `windowHeight` points tall (stored; nothing re-fits it later).
    func fitTimelineHeight(windowHeight: CGFloat) {
        layout.fitTimeline(contentHeight: timelineContentHeight, windowHeight: windowHeight)
    }

    /// The timeline's content model. Rebuilt only when what it draws changes (review M7): after a
    /// model change (or a lane collapse or reveal) the drawn content is assembled from the snapshots
    /// and compared with the cached one; an edit that changes nothing drawn (a Ken Burns drag step, a
    /// span's values, a clip's Motion) reuses the cached model, so the canvas has nothing new to draw.
    private var timelineContent: TimelineViewModel {
        let key = TimelineCacheKey(changeCount: changeCount, collapsedTracks: collapsedTrackIDs,
                                   collapsedLanes: layout.collapsedLaneTracks,
                                   revealedTransitionTrack: revealedTransitionTrack)
        if let cached = cachedTimeline, cached.key == key {
            return cached.model
        }
        let drawn = drawnTimeline()
        if let cached = cachedTimeline, cached.drawn == drawn {
            cachedTimeline = (key, drawn, cached.model)
            return cached.model
        }
        timelineBuildCount += 1
        var model = TimelineViewModel()
        model.frameSeconds = drawn.frameSeconds
        model.tracks = drawn.tracks
        model.clips = drawn.clips
        model.spans = drawn.spans
        cachedTimeline = (key, drawn, model)
        return model
    }

    /// Everything the timeline's content model is made of, from the snapshots (sorted, so equal
    /// content compares equal).
    private func drawnTimeline() -> DrawnTimeline {
        let occupied = Set(clips.values.map(\.trackID))
        var spans: [TimelineViewModel.Span] = []
        for clip in clips.values {
            for span in clip.spans {
                spans.append(Self.timelineSpan(span, of: clip))
            }
        }
        let spansByTrack = Dictionary(grouping: spans, by: \.trackID)
        let rows: [TimelineViewModel.Track] = tracks.map {
            let kind: TimelineViewModel.TrackKind = $0.kind == .video ? .video : .audio
            let hasClips = occupied.contains($0.trackID)
            let lanesCollapsed = layout.collapsedLaneTracks.contains(
                WindowLayoutModel.laneKey(video: kind == .video, index: $0.index))
            var track = TimelineViewModel.Track(id: $0.trackID, kind: kind, index: $0.index,
                                                name: $0.name, muted: $0.muted, solo: $0.solo, locked: $0.locked,
                                                isEmpty: !hasClips,
                                                collapsed: collapsedTrackIDs.contains($0.trackID) && !hasClips)
            track.lanesCollapsed = lanesCollapsed
            track.lanes = TimelineViewModel.lanes(hasClips: hasClips, spans: spansByTrack[$0.trackID] ?? [],
                                                  collapsed: lanesCollapsed,
                                                  revealTransitionLane: revealedTransitionTrack == $0.trackID)
            return track
        }
        let drawnClips: [TimelineViewModel.Clip] = clips.values.map {
            let audio = $0.audioParams
            return TimelineViewModel.Clip(id: $0.clipID, trackID: $0.trackID, assetID: $0.assetID, name: $0.name,
                                          start: $0.timelineStart.secondsOrZero, end: $0.timelineEnd.secondsOrZero,
                                          sourceIn: $0.sourceIn.secondsOrZero, speed: $0.speed,
                                          linkedClipID: $0.linkedClipID, isStill: $0.isStill,
                                          isAudio: $0.trackKind == .audio, gainDb: audio.gainDb,
                                          fadeIn: audio.fadeInDuration.secondsOrZero,
                                          fadeOut: audio.fadeOutDuration.secondsOrZero)
        }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        return DrawnTimeline(frameSeconds: frameDuration.secondsOrZero, tracks: rows, clips: drawnClips,
                             spans: spans.sorted { ($0.trackID, $0.lane, $0.start, $0.id) < ($1.trackID, $1.lane, $1.start, $1.id) })
    }

    /// A span of `clip` as the timeline draws it (timeline seconds).
    private static func timelineSpan(_ span: VEEffectSpan, of clip: VEClipInfo) -> TimelineViewModel.Span {
        let kind: TimelineViewModel.SpanKind
        switch span.kind {
        case .transition: kind = .transition
        case .motion: kind = .motion
        case .opacity: kind = .opacity
        case .gain: kind = .gain
        @unknown default: kind = .motion
        }
        let style: TimelineViewModel.TransitionStyle
        switch span.transitionStyle {
        case .fadeIn: style = .fadeIn
        case .fadeOut: style = .fadeOut
        default: style = .crossDissolve
        }
        let cut = style == .fadeIn ? clip.timelineStart : clip.timelineEnd
        return TimelineViewModel.Span(id: span.spanID, clipID: clip.clipID, trackID: clip.trackID, lane: span.lane,
                                      kind: kind, start: span.start.secondsOrZero, end: span.end.secondsOrZero,
                                      style: style, cut: cut.secondsOrZero, isAudio: clip.trackKind == .audio)
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
            statusMessage = notes(of: result)
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
        clampTimelineScroll()
    }

    /// Keeps the timeline's scroll offsets inside its content (review M5): after every model change,
    /// a lane collapse or reveal, a track row collapse, a zoom, a scroll and a resize of the track
    /// area, so rows that got shorter never leave the top rows hidden above blank space. Nothing is
    /// clamped until the timeline has been laid out (its viewport size is known).
    func clampTimelineScroll() {
        guard timelineViewportWidth > 0, timelineViewportHeight > 0 else { return }
        let model = timelineModel
        let x = min(max(0, scrollX), max(0, model.contentWidth - timelineViewportWidth))
        let y = min(max(0, scrollY), max(0, model.contentHeight - timelineViewportHeight))
        if x != scrollX { scrollX = x }
        if y != scrollY { scrollY = y }
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
        clampTimelineScroll()
    }

    /// Whether the track's row is shown collapsed (collapsed and still empty).
    func isTrackCollapsed(_ id: VETrackID) -> Bool {
        collapsedTrackIDs.contains(id) && isTrackEmpty(id)
    }

    /// Collapses or expands a track's lanes (remembered in the window layout by the track's kind and
    /// number, `WindowLayoutModel.laneKey`).
    func setLanes(ofTrack id: VETrackID, collapsed: Bool) {
        guard let track = track(id) else { return }
        layout.setLanesCollapsed(collapsed, key: WindowLayoutModel.laneKey(video: track.kind == .video,
                                                                          index: track.index))
        clampTimelineScroll()
    }

    /// Lane collapse is kept by the track's kind and number ("V2"); when tracks are removed, added
    /// or reordered within a project the numbers of the others change, so the collapse moves with
    /// its track (review L7: deleting V1 made V2's collapse state V1's). A track that is gone takes
    /// its state with it; keys of numbers no track had are left alone. Not across projects (their
    /// track ids restart; `resetUIState` empties `tracks` first).
    private func followLaneCollapse(from previous: [VETrackInfo]) {
        guard !previous.isEmpty, !replacingProject else { return }
        let before = Dictionary(previous.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(tracks.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ track: VETrackInfo) -> String {
            WindowLayoutModel.laneKey(video: track.kind == .video, index: track.index)
        }
        let moved = before.values.contains { old in after[old.trackID].map { key($0) != key(old) } ?? true }
            || after.values.contains { before[$0.trackID] == nil }
        guard moved else { return }
        let collapsed = layout.collapsedLaneTracks
        var keys = collapsed.subtracting(previous.map(key))
        for old in previous where collapsed.contains(key(old)) {
            if let now = after[old.trackID] { keys.insert(key(now)) }
        }
        if keys != collapsed { layout.setCollapsedLaneTracks(keys) }
    }

    /// Opens the lanes of the track holding span `id` when they are collapsed.
    private func revealLanes(ofSpan id: VESpanID) {
        guard let span = engine.spanInfo(id), areLanesCollapsed(ofTrack: span.trackID) else { return }
        setLanes(ofTrack: span.trackID, collapsed: false)
    }

    /// Whether the user collapsed the track's lanes.
    func areLanesCollapsed(ofTrack id: VETrackID) -> Bool {
        guard let track = track(id) else { return false }
        return layout.collapsedLaneTracks.contains(WindowLayoutModel.laneKey(video: track.kind == .video,
                                                                              index: track.index))
    }

    /// The track header's disclosure: an empty track collapses its row, a track with clips its lanes.
    func toggleDisclosure(ofTrack id: VETrackID) {
        if isTrackEmpty(id) {
            setTrack(id, collapsed: !isTrackCollapsed(id))
        } else {
            setLanes(ofTrack: id, collapsed: !areLanesCollapsed(ofTrack: id))
        }
    }

    /// Shows lane 0 on the track `id` while a transition is dragged over its row (nil when none is),
    /// so it can be dropped there; only that row grows, below its clips. Publishes only a change.
    func revealTransitionLane(onTrack id: VETrackID?) {
        if revealedTransitionTrack != id { revealedTransitionTrack = id }
        if id == nil { clampTimelineScroll() }
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
        case .timeline: return !selection.isEmpty || selectedSpanID != nil
        case .sourceMonitor: return false
        }
    }

    /// Delete / Shift+Delete, for the focused panel: in the media bin they remove the selected
    /// asset (refused while clips use it), in the timeline they remove (or ripple delete) the
    /// selected clips, or remove the selected span (a transition with its linked one; one undo
    /// step); with the source monitor focused they do nothing. Ignored during a gesture.
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
        if selection.isEmpty, let span = selectedSpanID {
            if engine.transitionInfo(span) != nil {
                // A dissolve goes with its linked crossfade (they were added as one step).
                removeTransition(span, includingLinked: true)
            } else {
                removeSpan(span)
            }
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
        if let selected = selectedSpanID, engine.spanInfo(selected) == nil { selectedSpanID = nil }
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

    // MARK: Neighbours

    /// The clip on the same track touching `id` at `edge`: the previous clip ending exactly where it
    /// starts (`.start`) or the next one starting exactly where it ends (`.end`); nil for a gap.
    func adjacentClip(to id: VEClipID, at edge: VEClipEdge) -> VEClipInfo? {
        let other = engine.adjacentClip(of: id, at: edge)
        return other != 0 ? clips[other] : nil
    }

    // MARK: Ken Burns

    /// Opens, updates or closes the Ken Burns editor after the selection or the model changed: open
    /// on the selected Motion span (unless the user closed it for that span), switched when another
    /// Motion span is selected, updated with the span as it is now, closed for anything else. Opening
    /// pauses playback. A clip without a picture says why in the status line.
    func syncKenBurns() {
        guard let id = selectedSpanID, kenBurnsClosedSpan != id, let span = engine.spanInfo(id), span.kind == .motion,
              let clip = clips[span.clipID] ?? engine.clipInfo(span.clipID) else {
            if kenBurns != nil { kenBurns = nil }
            return
        }
        let previous = adjacentClip(to: clip.clipID, at: .start)
        let next = adjacentClip(to: clip.clipID, at: .end)
        if let kenBurns, kenBurns.spanID == id {
            kenBurns.update(span: span, clip: clip, previous: previous, next: next)
            return
        }
        kenBurns?.cancelDrag()
        // It could not open for this span: said once, not retried on every model change.
        guard kenBurnsFailedSpan != id else {
            if kenBurns != nil { kenBurns = nil }
            return
        }
        guard let info = asset(clip.assetID) else {
            failKenBurns(id, "The media of “\(clip.name)” is not in the project, so Ken Burns has no picture.")
            return
        }
        // The loader is made only for a span the editor can open.
        if let reason = KenBurnsModel.problem(span: span, clip: clip, asset: info, sequence: sequence) {
            failKenBurns(id, reason)
            return
        }
        var reason = ""
        let picture = KenBurnsPictureLoader(assetID: info.assetID, engine: engine)
        guard let model = KenBurnsModel(store: self, span: span, clip: clip, asset: info, sequence: sequence,
                                        playhead: playheadTime, picture: picture, previous: previous, next: next,
                                        reason: &reason) else {
            failKenBurns(id, reason)
            return
        }
        engine.pause()
        kenBurns = model
    }

    private func failKenBurns(_ id: VESpanID, _ reason: String) {
        kenBurns = nil
        kenBurnsFailedSpan = id
        kenBurnsOpenFailures += 1
        statusMessage = reason
    }

    /// Ken Burns… in the inspector, or a click on the selected Motion span: selects the span and
    /// (re)opens its editor.
    func showKenBurns(span id: VESpanID) {
        guard engine.spanInfo(id)?.kind == .motion else { return }
        kenBurnsClosedSpan = nil
        kenBurnsFailedSpan = nil // asked for explicitly: try again
        if selectedSpanID != id {
            select(span: id)
        } else {
            syncKenBurns()
        }
    }

    /// Escape (no drag in progress) or the editor's Close button: closes the Ken Burns editor; the
    /// span stays selected (the inspector shows it).
    func closeKenBurns() {
        guard let kenBurns else { return }
        kenBurns.cancelDrag()
        kenBurnsClosedSpan = kenBurns.spanID
        self.kenBurns = nil
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
        replacingProject = true
        defer { replacingProject = false }
        engine.newProject(withName: "Untitled")
        resetUIState()
    }

    func open(url: URL) throws {
        cancelActiveGesture?()
        replacingProject = true
        defer { replacingProject = false }
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
        kenBurns?.cancelDrag()
        kenBurns = nil
        kenBurnsClosedSpan = nil
        kenBurnsFailedSpan = nil
        // Media still arriving belongs to the previous project (its Media folder).
        incoming.discardAll()
        mediaFolder.reset()
        thumbnails.removeAll()
        waveforms.removeAll()
        selection = []
        selectedSpanID = nil
        selectedAssetID = nil
        revealedTransitionTrack = nil
        collapsedTrackIDs = [] // track ids restart per project
        source = SourceMonitorState()
        sourcePlayhead.reset()
        playhead.apply(engine.playbackStatus)
        scrollX = 0
        scrollY = 0
        statusMessage = nil
        spanMemory.forget() // span ids restart per project
        refreshAssets()
        refreshModel()
    }
}
