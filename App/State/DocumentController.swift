import AppKit
import Foundation
import UniformTypeIdentifiers

/// File menu behaviour for the single-window app: New / Open / Open Recent / Save / Save As,
/// unsaved-changes confirmation (once per close: closing the window with unsaved changes asks,
/// and the app quitting because its last window closed does not ask again) and the recent
/// projects list.
///
/// Recent projects are kept as security-scoped bookmarks in UserDefaults so they can be
/// reopened from inside the App Sandbox. Alerts and the save panel go through `runAlert` and
/// `chooseSaveURL`, which tests replace.
@MainActor
final class DocumentController: ObservableObject {
    static let recentsKey = "recentProjectBookmarks"
    static let maxRecents = 10

    let store: ProjectStore
    @Published private(set) var recentURLs: [URL] = []
    /// Security-scoped access to the open project file (opened from recents).
    private var accessedProjectURL: URL?
    private let defaults: UserDefaults
    /// The model version the user last answered the unsaved-changes question for when closing
    /// the window (Save or Don't Save); quitting at that version does not ask again.
    private var closeConfirmedAtChange: UInt64?

    /// Runs an alert modally and returns the button chosen.
    var runAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    /// Asks where to save (the suggested file name is given); nil when cancelled.
    var chooseSaveURL: (String) -> URL? = { suggestedName in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.videditProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    init(store: ProjectStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        recentURLs = resolveRecents()
    }

    // MARK: Actions

    func newProject() {
        guard confirmStoppingExport(because: "Starting a new project"), confirmDiscardingChanges() else { return }
        store.newProject()
        stopAccessingProject()
    }

    func openWithPanel() {
        guard confirmStoppingExport(because: "Opening another project"), confirmDiscardingChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.videditProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func openRecent(_ url: URL) {
        guard confirmStoppingExport(because: "Opening another project"), confirmDiscardingChanges() else { return }
        open(url)
    }

    /// Opens `url` (no confirmation); reports errors in an alert, and what had to be adjusted to
    /// load the file in an informational one.
    func open(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            try store.open(url: url)
            stopAccessingProject()
            if accessing { accessedProjectURL = url }
            noteRecent(url)
            let warnings = store.engine.loadWarnings
            if !warnings.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "“\(store.projectName)” was adjusted to open in this version."
                alert.informativeText = warnings.joined(separator: "\n")
                _ = runAlert(alert)
            }
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            presentError(error, title: "The project could not be opened.")
        }
    }

    /// Saves to the current file, or asks where. Returns false if cancelled or failed.
    @discardableResult
    func save() -> Bool {
        if let url = store.projectURL {
            return save(to: url)
        }
        return saveAs()
    }

    @discardableResult
    func saveAs() -> Bool {
        guard let url = chooseSaveURL(store.projectName + ".videdit") else { return false }
        return save(to: url)
    }

    private func save(to url: URL) -> Bool {
        do {
            try store.save(to: url)
            noteRecent(url)
            return true
        } catch {
            presentError(error, title: "The project could not be saved.")
            return false
        }
    }

    /// Asks to save unsaved changes. Returns true when it is fine to continue (saved or
    /// discarded), false when the user cancelled.
    func confirmDiscardingChanges() -> Bool {
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(store.projectName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch runAlert(alert) {
        case .alertFirstButtonReturn:
            return save()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// The window is closing: asks about unsaved changes; the answer also covers the app
    /// quitting right after (the last window closed).
    func confirmClosingWindow() -> Bool {
        guard confirmStoppingExport(because: "Closing the window"), confirmDiscardingChanges() else { return false }
        closeConfirmedAtChange = store.changeCount
        return true
    }

    /// The app is quitting: asks about unsaved changes unless the user just answered for this
    /// exact state when closing the window.
    func shouldTerminate() -> Bool {
        guard confirmStoppingExport(because: "Quitting") else { return false }
        if let confirmed = closeConfirmedAtChange, confirmed == store.changeCount {
            return true
        }
        return confirmDiscardingChanges()
    }

    /// An export is running: asks whether to stop it. Stop Export cancels it and waits (up to 2 s)
    /// until its unfinished file is deleted. Returns true when no export runs or it was stopped.
    func confirmStoppingExport(because action: String) -> Bool {
        guard let export = store.engine.activeExport, !export.isFinished else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An export is in progress."
        alert.informativeText = "\(action) stops the export of “\(export.outputURL.lastPathComponent)” "
            + "and deletes the unfinished file."
        alert.addButton(withTitle: "Stop Export")
        alert.addButton(withTitle: "Keep Exporting")
        guard runAlert(alert) == .alertFirstButtonReturn else { return false }
        _ = export.cancelAndWait(withTimeout: 2)
        return true
    }

    // MARK: Recents

    func clearRecents() {
        defaults.removeObject(forKey: Self.recentsKey)
        recentURLs = []
    }

    private func noteRecent(_ url: URL) {
        let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        guard let bookmark = scoped ?? (try? url.bookmarkData()) else { return }
        var entries = (defaults.array(forKey: Self.recentsKey) as? [Data]) ?? []
        entries.removeAll { data in
            var stale = false
            let existing = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            return existing?.standardizedFileURL == url.standardizedFileURL
        }
        entries.insert(bookmark, at: 0)
        defaults.set(Array(entries.prefix(Self.maxRecents)), forKey: Self.recentsKey)
        recentURLs = resolveRecents()
    }

    private func resolveRecents() -> [URL] {
        let entries = (defaults.array(forKey: Self.recentsKey) as? [Data]) ?? []
        return entries.compactMap { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                             bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                             bookmarkDataIsStale: &stale))
        }
    }

    private func stopAccessingProject() {
        accessedProjectURL?.stopAccessingSecurityScopedResource()
        accessedProjectURL = nil
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        _ = runAlert(alert)
    }
}
