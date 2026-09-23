import SwiftUI
import FramewrightEngine

@main
struct FramewrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ProjectStore
    @StateObject private var documents: DocumentController
    private let keyboard: KeyboardController

    init() {
        let store = ProjectStore()
        Preferences.apply(to: store.engine)
        _store = StateObject(wrappedValue: store)
        _documents = StateObject(wrappedValue: DocumentController(store: store))
        keyboard = KeyboardController(store: store)
    }

    var body: some Scene {
        Window("Framewright", id: "main") {
            ContentView(store: store, documents: documents)
                .onAppear {
                    appDelegate.documents = documents
                    keyboard.install()
                }
        }
        .commands {
            AppCommands(store: store, documents: documents)
        }
        Settings {
            PreferencesView(engine: store.engine)
        }
        Window("Acknowledgements", id: AcknowledgementsView.windowID) {
            AcknowledgementsView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// Menu bar commands. Bare-key shortcuts (Space, J/K/L, arrows, Home/End, Delete, I/O, =/-) are
/// handled by `KeyboardController` so they never steal keys from text fields; the menu items
/// below show them for discoverability. Edit commands are ignored while a gesture is in progress
/// (`ProjectStore.isGestureActive`).
struct AppCommands: Commands {
    @ObservedObject var store: ProjectStore
    @ObservedObject var documents: DocumentController
    @ObservedObject var layout: WindowLayoutModel
    @ObservedObject var output: OutputDisplayController
    @AppStorage(PlaybackHUD.defaultsKey) private var showPlaybackHUD = false
    @Environment(\.openWindow) private var openWindow

    init(store: ProjectStore, documents: DocumentController) {
        self.store = store
        self.documents = documents
        layout = store.layout
        output = store.outputDisplay
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Acknowledgements…") { openWindow(id: AcknowledgementsView.windowID) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Project") { documents.newProject() }
                .keyboardShortcut("n")
            Button("Open…") { documents.openWithPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(documents.recentURLs, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { documents.openRecent(url) }
                }
                Divider()
                Button("Clear Menu") { documents.clearRecents() }
                    .disabled(documents.recentURLs.isEmpty)
            }
            Divider()
            Button("Import Media…") { presentImportPanel(store: store) }
                .keyboardShortcut("i")
            Button("Import from Photos…") { store.photosPicker.present() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { documents.save() }
                .keyboardShortcut("s")
            Button("Save As…") { documents.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export…") { store.showExportSheet() }
                .keyboardShortcut("e")
                .disabled(store.isGestureActive || store.isExporting || store.exportModel != nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(store.undoActionName.isEmpty ? "Undo" : "Undo \(store.undoActionName)") {
                if !Self.forwardToTextField(undo: true) { store.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!store.canUndo && !Self.textFieldCan(undo: true))
            Button(store.redoActionName.isEmpty ? "Redo" : "Redo \(store.redoActionName)") {
                if !Self.forwardToTextField(undo: false) { store.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo && !Self.textFieldCan(undo: false))
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Reset Video Settings") { store.resetSettings(.video) }
                .disabled(!store.selectedClips.contains { $0.trackKind == .video })
            Button("Reset Audio Settings") { store.resetSettings(.audio) }
                .disabled(!store.selectedClips.contains { $0.trackKind == .audio })
        }
        CommandMenu("Clip") {
            Button("Split at Playhead") { store.splitAtPlayhead() }
                .keyboardShortcut("k")
            Button("Split at Playhead, Removing Transitions") { store.splitAtPlayhead(breakingTransitions: true) }
                .keyboardShortcut("k", modifiers: [.command, .option])
            Button("Delete  ⌫") { store.deleteSelection(ripple: false) }
                .disabled(!store.canDelete)
            Button("Delete Transition Only  ⌥⌫") { store.deleteSelectedTransitionOnly() }
                .disabled(store.focusArea != .timeline || !store.selection.isEmpty || store.selectedTransitionID == nil)
            Button("Ripple Delete  ⇧⌫") { store.deleteSelection(ripple: true) }
                .disabled(store.focusArea != .timeline || store.selection.isEmpty)
            Divider()
            Button("Link / Unlink") { store.linkOrUnlinkSelection() }
                .keyboardShortcut("l")
            Button("Speed/Duration…") { store.showSpeedSheet() }
                .keyboardShortcut("r")
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Add Cross Dissolve") { store.addTransitionAtPlayhead(.crossDissolve) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Add Audio Crossfade") { store.addTransitionAtPlayhead(.audioCrossfade) }
                .keyboardShortcut("d", modifiers: [.command, .shift, .option])
            Button("Transition Duration…") { store.editTransitionDuration() }
                .disabled(store.selectedTransitionID == nil)
            Divider()
            Button("Raise Gain 1 dB  ]") { store.nudgeGain(1) }
                .disabled(store.selection.isEmpty)
            Button("Lower Gain 1 dB  [") { store.nudgeGain(-1) }
                .disabled(store.selection.isEmpty)
            Divider()
            Button("Select All Clips  ⌘A") { store.selectAll() }
            Button("Insert from Source") { store.placeSource(overwrite: false) }
            Button("Overwrite from Source") { store.placeSource(overwrite: true) }
        }
        CommandMenu("Playback") {
            // Playback does not start while an export runs (the engine refuses it too).
            Button("Play / Pause  Space") { store.playbackActions.togglePlay() }
                .disabled(store.isExporting)
            Button("Play Backwards  J") { store.playbackActions.shuttleReverse() }
                .disabled(store.isExporting)
            Button("Stop  K") { store.playbackActions.shuttleStop() }
            Button("Play Forwards  L") { store.playbackActions.shuttleForward() }
                .disabled(store.isExporting)
            Divider()
            Button("Previous Frame  ←") { store.playbackActions.stepFrames(-1) }
            Button("Next Frame  →") { store.playbackActions.stepFrames(1) }
            Button("Go to Start  Home") { store.playbackActions.goToStart() }
            Button("Go to End  End") { store.playbackActions.goToEnd() }
            Divider()
            Button("Mute Audio") { store.engine.isMuted.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Source Monitor", isOn: Binding(get: { layout.showsSourceMonitor },
                                                        set: { store.setSourceMonitorVisible($0) }))
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Toggle("Program Monitor on Second Display", isOn: Binding(get: { output.isShowing },
                                                                      set: { _ in output.toggle() }))
                .disabled(!output.isAvailable && !output.isShowing)
            Picker("Right Panel", selection: $layout.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            Button("Reset Window Layout") {
                store.setSourceMonitorVisible(false)
                layout.resetToDefaults()
            }
            Divider()
            Toggle("Show Playback HUD", isOn: $showPlaybackHUD)
                .keyboardShortcut("h", modifiers: [.command, .option])
            Divider()
            // Also bare = / + and - (KeyboardController).
            Button("Zoom In") { store.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { store.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit Sequence") { store.zoomToFit(width: store.timelineViewportWidth) }
                .keyboardShortcut("0")
            Divider()
        }
    }

    /// While a text field is being edited, Undo/Redo go to its own undo manager.
    @MainActor
    private static func forwardToTextField(undo: Bool) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, let manager = text.undoManager else { return false }
        if undo, manager.canUndo {
            manager.undo()
            return true
        }
        if !undo, manager.canRedo {
            manager.redo()
            return true
        }
        return false
    }

    @MainActor
    private static func textFieldCan(undo: Bool) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, let manager = text.undoManager else { return false }
        return undo ? manager.canUndo : manager.canRedo
    }
}
